#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
STACK_ENV="$CONFIG_DIR/stack.env"
GATEWAY_ENV="$CONFIG_DIR/gateway.env"
INSTALL_DIR="$HOME/.local/share/exocortex-gateway"
VENV_DIR="$HOME/.local/share/exocortex-gateway-venv"
SERVICE_FILE="$HOME/.config/systemd/user/exocortex-claude-router.service"
[[ -r "$STACK_ENV" && -r "$GATEWAY_ENV" ]] || { echo 'Run the gateway deployment first.' >&2; exit 1; }
set -a; . "$STACK_ENV"; . "$GATEWAY_ENV"; set +a
install -m 0644 "$SCRIPT_DIR/proposals/exocortex-gateway/claude_router.py" "$INSTALL_DIR/claude_router.py"
router_key="$(sed -n 's/^EXOCORTEX_CLAUDE_ROUTER_KEY=//p' "$GATEWAY_ENV" | head -1)"
if [[ -z "$router_key" ]]; then
  router_key="$(openssl rand -hex 32)"
  printf 'EXOCORTEX_CLAUDE_ROUTER_KEY=%s\n' "$router_key" >>"$GATEWAY_ENV"
fi
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Exocortex Claude Code smart router (no persistence)
After=network-online.target litellm-qwen.service
[Service]
EnvironmentFile=$GATEWAY_ENV
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/uvicorn claude_router:app --host 127.0.0.1 --port 4011
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable exocortex-claude-router.service
systemctl --user restart exocortex-claude-router.service
for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:4011/health && exit 0; sleep 1; done
systemctl --user status exocortex-claude-router.service --no-pager -l >&2
exit 1
