#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
OWNER="${SUDO_USER:-}"
[[ -n "$OWNER" && "$OWNER" != root ]] || { echo 'Run via sudo from the intended owner account.' >&2; exit 1; }

VAULT_FILE="${EXOCORTEX_BIOMETRIC_VAULT_FILE:-/var/lib/exocortex-vault/biometrics.luks}"
MOUNT_POINT="${EXOCORTEX_BIOMETRIC_MOUNT_POINT:-/var/lib/exocortex/biometrics}"
MAPPER_NAME="${EXOCORTEX_BIOMETRIC_MAPPER_NAME:-exocortex-biometrics}"
SIZE_MIB="${EXOCORTEX_BIOMETRIC_VAULT_SIZE_MIB:-2048}"
CONFIG_FILE="${EXOCORTEX_BIOMETRIC_CONFIG_FILE:-/etc/exocortex/biometric-vault.conf}"
HEADER_BACKUP="${EXOCORTEX_BIOMETRIC_HEADER_BACKUP:-/home/$OWNER/exocortex-biometric-vault-header.img}"
SPEAKER_UID="${EXOCORTEX_SPEAKER_UID:-10004}"
SPEAKER_GID="${EXOCORTEX_SPEAKER_GID:-10004}"

[[ "$VAULT_FILE" == /var/lib/exocortex-vault/*.luks ]] || { echo 'Refusing unexpected vault path.' >&2; exit 1; }
[[ "$MOUNT_POINT" == /var/lib/exocortex/biometrics ]] || { echo 'Refusing unexpected mount point.' >&2; exit 1; }
[[ "$MAPPER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid mapper name.' >&2; exit 1; }
[[ "$SIZE_MIB" =~ ^[0-9]+$ && "$SIZE_MIB" -ge 256 && "$SIZE_MIB" -le 16384 ]] || { echo 'Vault size must be 256-16384 MiB.' >&2; exit 1; }
[[ "$SPEAKER_UID" =~ ^[0-9]+$ && "$SPEAKER_GID" =~ ^[0-9]+$ ]] || { echo 'Speaker UID and GID must be numeric.' >&2; exit 1; }
[[ ! -e "$VAULT_FILE" ]] || { echo "Vault already exists: $VAULT_FILE" >&2; exit 1; }
[[ ! -e "/dev/mapper/$MAPPER_NAME" ]] || { echo "Mapper already exists: $MAPPER_NAME" >&2; exit 1; }

install -d -m 0700 "$(dirname -- "$VAULT_FILE")"
install -d -m 0755 "$(dirname -- "$MOUNT_POINT")"
install -d -m 0700 "$(dirname -- "$CONFIG_FILE")"
fallocate -l "${SIZE_MIB}M" "$VAULT_FILE"
chmod 0600 "$VAULT_FILE"

loop_device=''
opened=0
cleanup_failure() {
  status=$?
  if (( status != 0 )); then
    (( opened == 1 )) && cryptsetup close "$MAPPER_NAME" 2>/dev/null || true
    [[ -n "$loop_device" ]] && losetup -d "$loop_device" 2>/dev/null || true
    rm -f -- "$VAULT_FILE"
  fi
  exit "$status"
}
trap cleanup_failure EXIT

loop_device="$(losetup --find --show "$VAULT_FILE")"
echo 'Create a strong vault passphrase. It is never written to disk or Git.'
cryptsetup luksFormat --type luks2 --pbkdf argon2id "$loop_device"
cryptsetup open "$loop_device" "$MAPPER_NAME"
opened=1
mkfs.ext4 -q -L exocortex-biometrics "/dev/mapper/$MAPPER_NAME"
install -d -m 0700 "$MOUNT_POINT"
mount -o nodev,nosuid,noexec "/dev/mapper/$MAPPER_NAME" "$MOUNT_POINT"
install -d -m 0700 -o "$SPEAKER_UID" -g "$SPEAKER_GID" "$MOUNT_POINT/voiceprints"
install -d -m 0700 -o "$SPEAKER_UID" -g "$SPEAKER_GID" "$MOUNT_POINT/cache"
luks_uuid="$(cryptsetup luksUUID "$loop_device")"
printf 'luks_uuid=%s\n' "$luks_uuid" >"$MOUNT_POINT/.luks2-verified"
chown "$SPEAKER_UID:$SPEAKER_GID" "$MOUNT_POINT/.luks2-verified"
chmod 0400 "$MOUNT_POINT/.luks2-verified"

cryptsetup luksHeaderBackup "$loop_device" --header-backup-file "$HEADER_BACKUP"
chown "$OWNER:$OWNER" "$HEADER_BACKUP"
chmod 0600 "$HEADER_BACKUP"

printf '%s\n' \
  "VAULT_FILE='$VAULT_FILE'" \
  "MOUNT_POINT='$MOUNT_POINT'" \
  "MAPPER_NAME='$MAPPER_NAME'" \
  "SPEAKER_UID='$SPEAKER_UID'" \
  "SPEAKER_GID='$SPEAKER_GID'" >"$CONFIG_FILE"
chmod 0600 "$CONFIG_FILE"

trap - EXIT
cat <<EOF
Encrypted biometric vault created and mounted at $MOUNT_POINT.
Move $HEADER_BACKUP to encrypted off-device recovery storage.
The header backup does not replace your passphrase. No voiceprint exists yet.
EOF
