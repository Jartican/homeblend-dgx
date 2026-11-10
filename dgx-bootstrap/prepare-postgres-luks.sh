#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER_FILE="${EXOCORTEX_LUKS_CONTAINER:-/var/lib/exocortex-secure/postgres.luks}"
MAPPER_NAME="${EXOCORTEX_LUKS_MAPPER:-exocortex-postgres}"
MOUNT_POINT="${EXOCORTEX_ENCRYPTED_MOUNT:-/srv/exocortex/postgres}"
VOLUME_SIZE="${EXOCORTEX_LUKS_SIZE:-64G}"
CONFIRMATION="${1:-}"

[[ "$EUID" -eq 0 ]] || { echo 'Run as root.' >&2; exit 2; }
[[ "$CONFIRMATION" == PREPARE-NEW-POSTGRES-LUKS ]] || {
  echo 'Usage: sudo prepare-postgres-luks.sh PREPARE-NEW-POSTGRES-LUKS' >&2
  exit 2
}

case "$CONTAINER_FILE" in
  /var/lib/exocortex-secure/*.luks) ;;
  *) echo "Refusing unexpected container path: $CONTAINER_FILE" >&2; exit 2 ;;
esac
[[ "$MAPPER_NAME" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo 'Invalid mapper name.' >&2; exit 2; }
[[ "$MOUNT_POINT" == /srv/exocortex/postgres ]] || {
  echo "Refusing unexpected mount point: $MOUNT_POINT" >&2
  exit 2
}
[[ ! -e "$CONTAINER_FILE" ]] || { echo "Target already exists: $CONTAINER_FILE" >&2; exit 1; }
[[ ! -e "/dev/mapper/$MAPPER_NAME" ]] || { echo "Mapper already exists: $MAPPER_NAME" >&2; exit 1; }

install -d -m 0700 "$(dirname "$CONTAINER_FILE")"
install -d -m 0750 "$MOUNT_POINT"
[[ -z "$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
  echo "Mount point is not empty: $MOUNT_POINT" >&2
  exit 1
}

created=false
opened=false
mounted=false
cleanup_failure() {
  exit_code=$?
  if ((exit_code == 0)); then return; fi
  if [[ "$mounted" == true ]]; then umount "$MOUNT_POINT" || true; fi
  if [[ "$opened" == true ]]; then cryptsetup close "$MAPPER_NAME" || true; fi
  if [[ "$created" == true ]]; then
    echo "Preparation failed; the newly created container remains at $CONTAINER_FILE" >&2
  fi
}
trap cleanup_failure EXIT

fallocate -l "$VOLUME_SIZE" "$CONTAINER_FILE"
chmod 0600 "$CONTAINER_FILE"
created=true

echo 'Create a strong LUKS passphrase now. Store recovery material off the DGX.'
cryptsetup luksFormat --type luks2 "$CONTAINER_FILE"
cryptsetup open "$CONTAINER_FILE" "$MAPPER_NAME"
opened=true

mkfs.ext4 -L exocortex-postgres "/dev/mapper/$MAPPER_NAME"
mount -o nodev,nosuid "/dev/mapper/$MAPPER_NAME" "$MOUNT_POINT"
mounted=true

install -d -o 999 -g 999 -m 0700 "$MOUNT_POINT/data"
backup_owner="${SUDO_UID:-0}"
backup_group="${SUDO_GID:-0}"
install -d -o "$backup_owner" -g "$backup_group" -m 0700 "$MOUNT_POINT/backups"

echo "Prepared and mounted $CONTAINER_FILE at $MOUNT_POINT"
echo 'No PostgreSQL data was copied and no service configuration was changed.'
echo "After reboot, unlock interactively with: sudo systemd-cryptsetup attach $MAPPER_NAME $CONTAINER_FILE -"
