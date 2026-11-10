#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REQUIRE_ENCRYPTED_POSTGRES="${REQUIRE_ENCRYPTED_POSTGRES:-1}"
ENABLE_EXOCORTEX_UFW="${ENABLE_EXOCORTEX_UFW:-1}"

[[ "$(uname -m)" == aarch64 ]] || {
  echo 'This entry point must run on the DGX Spark (ARM64).' >&2
  exit 1
}
[[ $EUID -ne 0 ]] || {
  echo 'Run this as the intended non-root Exocortex user; it invokes sudo only for the privileged stage.' >&2
  exit 1
}

chmod +x "$SCRIPT_DIR"/*.sh

if [[ "$REQUIRE_ENCRYPTED_POSTGRES" == 1 ]]; then
  home_source="$(findmnt -n -o SOURCE -T "$HOME")"
  if [[ "$home_source" != /dev/* ]] || ! lsblk -s -n -o TYPE "$home_source" | grep -qx crypt; then
    cat >&2 <<EOF
Encrypted storage was not detected beneath $HOME.

Stop here if this is a fresh machine. Enable Ubuntu LUKS full-disk encryption
during OS provisioning, or provision a separate LUKS volume and set
POSTGRES_DATA_DIR to a directory mounted from it. Encryption of a populated
live root filesystem is a separate backup/reinstall/restore migration.
EOF
    exit 1
  fi
fi

root_env=(EXOCORTEX_USER="$USER")
[[ -n "${TAILSCALE_AUTH_KEY:-}" ]] && root_env+=(TAILSCALE_AUTH_KEY="$TAILSCALE_AUTH_KEY")
[[ -n "${TAILSCALE_HOSTNAME:-}" ]] && root_env+=(TAILSCALE_HOSTNAME="$TAILSCALE_HOSTNAME")
root_env+=(ENABLE_EXOCORTEX_UFW="$ENABLE_EXOCORTEX_UFW")

sudo env "${root_env[@]}" bash "$SCRIPT_DIR/bootstrap-root.sh"
bash "$SCRIPT_DIR/validate-bootstrap.sh"

if ! docker info >/dev/null 2>&1; then
  cat >&2 <<EOF
The privileged stage completed, but this login session does not yet have its
new Docker group membership. Log out and back in, return to $SCRIPT_DIR, and
run this same command again. The scripts preserve existing completed work.
EOF
  exit 2
fi

bash "$SCRIPT_DIR/bootstrap-dgx.sh"

if ! tailscale status --self >/dev/null 2>&1; then
  cat >&2 <<EOF
The Exocortex services are installed, but Tailscale is not enrolled yet.
Run 'sudo tailscale up', then run this same command again. For unattended
provisioning, pass a short-lived TAILSCALE_AUTH_KEY to this wrapper.
EOF
  exit 3
fi

# shellcheck disable=SC1090
. "$HOME/.config/exocortex/stack.env"
sudo tailscale serve --bg "${OPEN_WEBUI_PORT:-12000}"
bash "$SCRIPT_DIR/verify-dgx.sh"

echo
echo 'New DGX Spark bootstrap and verification completed.'
if [[ "${DEPLOY_PRIVATE_VOICE_STACK:-1}" == 1 ]]; then
  cat <<EOF
Voice Core is healthy but remains loopback-only and fail-closed until a signed
phone client is enrolled. Run:
  $SCRIPT_DIR/enroll-phone-client.sh iphone-primary
Save the one-time token in the phone Keychain, then publish only after:
  sudo $SCRIPT_DIR/configure-tailnet-voice.sh
EOF
fi
