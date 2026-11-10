#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
CONFIG_FILE="${EXOCORTEX_BIOMETRIC_CONFIG_FILE:-/etc/exocortex/biometric-vault.conf}"
[[ -r "$CONFIG_FILE" ]] || { echo "Missing $CONFIG_FILE." >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG_FILE"
[[ "$VAULT_FILE" == /var/lib/exocortex-vault/*.luks && "$MOUNT_POINT" == /var/lib/exocortex/biometrics ]] || {
  echo 'Refusing unexpected vault configuration.' >&2; exit 1;
}

# Release Docker's bind mount before unmounting the encrypted filesystem.
speaker_container="${SPEAKER_CONTAINER:-exocortex-speaker-verifier}"
if command -v docker >/dev/null && docker container inspect "$speaker_container" >/dev/null 2>&1; then
  docker stop "$speaker_container" >/dev/null
fi

mountpoint -q "$MOUNT_POINT" && umount "$MOUNT_POINT"
[[ ! -e "/dev/mapper/$MAPPER_NAME" ]] || cryptsetup close "$MAPPER_NAME"
while IFS=: read -r loop_device _; do
  [[ -n "$loop_device" ]] && losetup -d "$loop_device"
done < <(losetup -j "$VAULT_FILE")
echo 'Biometric vault locked. Voice verification remains unavailable until it is unlocked.'
