#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
STACK_ENV="$CONFIG_DIR/stack.env"
GATEWAY_ENV="$CONFIG_DIR/gateway.env"
INSTALL_DIR="$HOME/.local/share/exocortex-gateway"
VENV_DIR="$HOME/.local/share/exocortex-gateway-venv"
SERVICE_FILE="$HOME/.config/systemd/user/exocortex-home-blend.service"

[[ -r "$STACK_ENV" && -r "$GATEWAY_ENV" ]] || { echo 'Run the gateway deployment first.' >&2; exit 1; }
set -a; . "$STACK_ENV"; . "$GATEWAY_ENV"; set +a

bridge_ip="${EXOCORTEX_DOCKER_BRIDGE_IP:-$(ip -4 -o addr show docker0 | awk '{split($4,a,"/"); print a[1]; exit}')}"
[[ -n "$bridge_ip" ]] || { echo 'Could not resolve the docker0 IPv4 address.' >&2; exit 1; }
install -m 0644 "$SCRIPT_DIR/proposals/exocortex-gateway/home_blend_router.py" "$INSTALL_DIR/home_blend_router.py"

router_key="$(sed -n 's/^EXOCORTEX_HOME_ROUTER_KEY=//p' "$GATEWAY_ENV" | head -1)"
if [[ -z "$router_key" ]]; then
  router_key="$(openssl rand -hex 32)"
  printf 'EXOCORTEX_HOME_ROUTER_KEY=%s\n' "$router_key" >>"$GATEWAY_ENV"
fi

cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Exocortex Open WebUI home blend router (no persistence)
After=network-online.target docker.service litellm-qwen.service
[Service]
EnvironmentFile=$GATEWAY_ENV
Environment=EXOCORTEX_HOME_BLEND_MODEL=exocortex-home-blend
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/uvicorn home_blend_router:app --host $bridge_ip --port 4012
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable exocortex-home-blend.service
systemctl --user restart exocortex-home-blend.service
for _ in $(seq 1 30); do
  if curl -fsS "http://$bridge_ip:4012/health"; then
    printf '\nOpen WebUI connection URL: http://%s:4012/v1\n' "$bridge_ip"
    echo "Protected API key is EXOCORTEX_HOME_ROUTER_KEY in $GATEWAY_ENV"
    exit 0
  fi
  sleep 1
done
systemctl --user status exocortex-home-blend.service --no-pager -l >&2
exit 1
