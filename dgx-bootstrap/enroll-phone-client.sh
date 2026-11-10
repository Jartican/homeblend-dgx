#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
client_id="${1:-}"

[[ $EUID -ne 0 ]] || { echo 'Run as the intended non-root HomeBlend user.' >&2; exit 1; }
[[ "$client_id" =~ ^[a-z0-9][a-z0-9_.-]{0,63}$ ]] || {
  echo 'Usage: enroll-phone-client.sh CLIENT_ID' >&2
  echo 'Example: enroll-phone-client.sh iphone-primary' >&2
  exit 2
}

cat <<'EOF'
This creates one random Voice Core credential. Its raw value is shown once and
is never written to Git, stack.env, the DGX registry, or application logs.
Save it directly into the signed iPhone app's Voice Core credential field.
EOF

python3 "$SCRIPT_DIR/manage-voice-clients.py" enroll "$client_id"
"$SCRIPT_DIR/deploy-voice-gateway.sh" --mode production

cat <<EOF

The DGX now requires the enrolled application credential on WebSocket and HTTP
voice routes, but remains loopback-only. After saving the token in the signed
iPhone app, publish the authenticated route with:
  sudo $SCRIPT_DIR/configure-tailnet-voice.sh

If the token was lost before it reached the phone, revoke its credential ID
with manage-voice-clients.py, enroll a replacement, and redeploy production.
EOF
