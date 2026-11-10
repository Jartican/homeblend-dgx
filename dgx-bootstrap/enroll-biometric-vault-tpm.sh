#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ -e /dev/tpmrm0 || -e /dev/tpm0 ]] || {
  echo 'No TPM device is exposed by this DGX OS/firmware. Keep manual passphrase unlock; no changes made.' >&2
  exit 2
}
CONFIG_FILE="${EXOCORTEX_BIOMETRIC_CONFIG_FILE:-/etc/exocortex/biometric-vault.conf}"
# shellcheck disable=SC1090
. "$CONFIG_FILE"
loop_device="$(losetup -j "$VAULT_FILE" | cut -d: -f1 | head -n 1)"
[[ -n "$loop_device" ]] || loop_device="$(losetup --find --show "$VAULT_FILE")"
echo 'Enroll TPM2 with a user-entered PIN. This does not configure unattended boot mounting.'
systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes "$loop_device"
echo 'TPM2+PIN token enrolled. Test manual recovery before configuring any boot-time unlock.'
