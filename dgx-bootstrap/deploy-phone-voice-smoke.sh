#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="${1:-$HOME/dgx-bootstrap/phone-voice-smoke}"
INSTALL_DIR="${PHONE_VOICE_SMOKE_DIR:-$HOME/.local/share/homeblend-phone-test}"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/homeblend-phone-test.service"

[[ -r "$SOURCE_DIR/index.html" && -r "$SOURCE_DIR/server.py" ]] || {
  echo "Missing phone test source files beneath $SOURCE_DIR" >&2
  exit 2
}
install -d -m 0700 "$INSTALL_DIR" "$SERVICE_DIR"
install -m 0600 "$SOURCE_DIR/index.html" "$INSTALL_DIR/index.html"
install -m 0700 "$SOURCE_DIR/server.py" "$INSTALL_DIR/server.py"

cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=HomeBlend tailnet-only phone microphone test page
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/server.py
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable homeblend-phone-test.service >/dev/null
systemctl --user restart homeblend-phone-test.service
for attempt in {1..20}; do
  if curl -fsS http://127.0.0.1:8792/ >/dev/null; then
    break
  fi
  if [[ "$attempt" -eq 20 ]]; then
    echo 'Phone test service did not become ready' >&2
    systemctl --user --no-pager --full status homeblend-phone-test.service >&2 || true
    exit 1
  fi
  sleep 0.25
done

echo 'LOCAL_PHONE_TEST=ready http://127.0.0.1:8792/'
echo 'Tailscale Serve is intentionally not changed by this script.'
