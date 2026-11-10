#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
CONFIG_FILE="${EXOCORTEX_BIOMETRIC_CONFIG_FILE:-/etc/exocortex/biometric-vault.conf}"
[[ -r "$CONFIG_FILE" ]] || { echo "Missing $CONFIG_FILE." >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG_FILE"
[[ "$VAULT_FILE" == /var/lib/exocortex-vault/*.luks && "$MOUNT_POINT" == /var/lib/exocortex/biometrics ]] || exit 1
cryptsetup isLuks "$VAULT_FILE"
cryptsetup status "$MAPPER_NAME" | grep -q 'type:.*LUKS2'
source_device="$(findmnt -n -o SOURCE -T "$MOUNT_POINT")"
[[ "$source_device" == "/dev/mapper/$MAPPER_NAME" ]]
mount_options="$(findmnt -n -o OPTIONS -T "$MOUNT_POINT")"
for option in nodev nosuid noexec; do
  [[ ",$mount_options," == *",$option,"* ]] || { echo "Missing mount option: $option" >&2; exit 1; }
done
[[ "$(stat -c %a "$MOUNT_POINT/voiceprints")" == 700 ]]
[[ -f "$MOUNT_POINT/.luks2-verified" ]]
[[ "$(stat -c %a "$MOUNT_POINT/.luks2-verified")" == 400 ]]
[[ "$(stat -c %u:%g "$MOUNT_POINT/voiceprints")" == "$SPEAKER_UID:$SPEAKER_GID" ]]
echo 'ENCRYPTED_BIOMETRIC_VAULT=yes (LUKS2, mounted nodev/nosuid/noexec, dedicated speaker identity)'
