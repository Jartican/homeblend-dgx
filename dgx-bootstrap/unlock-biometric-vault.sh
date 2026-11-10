#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
CONFIG_FILE="${EXOCORTEX_BIOMETRIC_CONFIG_FILE:-/etc/exocortex/biometric-vault.conf}"
[[ -r "$CONFIG_FILE" ]] || { echo "Missing $CONFIG_FILE; create the vault first." >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG_FILE"
[[ "$VAULT_FILE" == /var/lib/exocortex-vault/*.luks && "$MOUNT_POINT" == /var/lib/exocortex/biometrics ]] || {
  echo 'Refusing unexpected vault configuration.' >&2; exit 1;
}

if mountpoint -q "$MOUNT_POINT"; then
  echo "Biometric vault is already mounted at $MOUNT_POINT."
  exit 0
fi

loop_device="$(losetup -j "$VAULT_FILE" | cut -d: -f1 | head -n 1)"
attached=0
if [[ -z "$loop_device" ]]; then
  loop_device="$(losetup --find --show "$VAULT_FILE")"
  attached=1
fi
cleanup_failure() {
  status=$?
  if (( status != 0 && attached == 1 )); then losetup -d "$loop_device" 2>/dev/null || true; fi
  exit "$status"
}
trap cleanup_failure EXIT

[[ -e "/dev/mapper/$MAPPER_NAME" ]] || cryptsetup open "$loop_device" "$MAPPER_NAME"
install -d -m 0700 "$MOUNT_POINT"
mount -o nodev,nosuid,noexec "/dev/mapper/$MAPPER_NAME" "$MOUNT_POINT"
trap - EXIT
echo "Biometric vault unlocked at $MOUNT_POINT."
