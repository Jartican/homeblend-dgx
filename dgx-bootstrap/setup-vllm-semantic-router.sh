#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
RUNTIME_DIR="${VLLM_SR_RUNTIME_DIR:-$HOME/.local/share/exocortex-vllm-sr}"
TEMPLATE="$SCRIPT_DIR/vllm-sr/config.template.yaml"
PROXY_SOURCE="$SCRIPT_DIR/vllm-sr/litellm_bridge_proxy.py"
ENVOY_TEMPLATE="$SCRIPT_DIR/vllm-sr/envoy.template.yaml"

[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "Missing $TEMPLATE" >&2; exit 1; }
[[ -f "$PROXY_SOURCE" ]] || { echo "Missing $PROXY_SOURCE" >&2; exit 1; }
[[ -f "$ENVOY_TEMPLATE" ]] || { echo "Missing $ENVOY_TEMPLATE" >&2; exit 1; }
for command in docker python3; do
  command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }
done

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

VLLM_SR_IMAGE="${VLLM_SR_IMAGE:-ghcr.io/vllm-project/semantic-router/vllm-sr@sha256:13f7bcfc5f2080682acf1458da9cf077d84dfa0bd7b95c9ab7544c754fec3b94}"
VLLM_SR_CONTAINER="${VLLM_SR_CONTAINER:-exocortex-vllm-sr-v06}"
VLLM_SR_ENVOY_CONTAINER="${VLLM_SR_ENVOY_CONTAINER:-exocortex-vllm-sr-v06-envoy}"
VLLM_SR_ENVOY_IMAGE="${VLLM_SR_ENVOY_IMAGE:-envoyproxy/envoy@sha256:cfc0678bc03cca19cbb031688acb31d510bff501ff97e163026a375fe0515d69}"
VLLM_SR_BIND="${VLLM_SR_BIND:-127.0.0.1}"
VLLM_SR_PORT="${VLLM_SR_PORT:-8899}"
VLLM_SR_MANAGEMENT_PORT="${VLLM_SR_MANAGEMENT_PORT:-18080}"
VLLM_SR_LITELLM_BRIDGE_PORT="${VLLM_SR_LITELLM_BRIDGE_PORT:-14000}"

[[ "$VLLM_SR_BIND" == 127.0.0.1 ]] || {
  echo 'Refusing non-loopback VLLM_SR_BIND. Use an authenticated tailnet proxy deliberately if remote access is needed.' >&2
  exit 1
}
[[ -n "${LITELLM_KEY:-}" ]] || { echo 'LITELLM_KEY must be set.' >&2; exit 1; }

install -d -m 700 "$RUNTIME_DIR/models"
install -m 700 "$PROXY_SOURCE" "$RUNTIME_DIR/litellm_bridge_proxy.py"
python3 - "$TEMPLATE" "$RUNTIME_DIR/config.yaml" <<'PY'
import json
import os
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
rendered = source.read_text(encoding="utf-8").replace('"__LITELLM_KEY__"', json.dumps(os.environ["LITELLM_KEY"]))
destination.write_text(rendered, encoding="utf-8")
PY
python3 - "$ENVOY_TEMPLATE" "$RUNTIME_DIR/envoy.yaml" <<'PY'
import json
import os
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
rendered = source.read_text(encoding="utf-8").replace('"Bearer __LITELLM_KEY__"', json.dumps("Bearer " + os.environ["LITELLM_KEY"]))
destination.write_text(rendered, encoding="utf-8")
PY
chmod 600 "$RUNTIME_DIR/config.yaml"
chmod 600 "$RUNTIME_DIR/envoy.yaml"

bridge_address="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"
[[ "$bridge_address" =~ ^172\.[0-9]+\.[0-9]+\.1$ ]] || {
  echo "Unexpected Docker bridge gateway: $bridge_address" >&2
  exit 1
}
unit_dir="$HOME/.config/systemd/user"
install -d -m 700 "$unit_dir"
cat > "$unit_dir/exocortex-vllm-sr-litellm-bridge.service" <<EOF
[Unit]
Description=Private Docker bridge to authenticated loopback LiteLLM
After=litellm-qwen.service docker.service

[Service]
ExecStart=/usr/bin/python3 $RUNTIME_DIR/litellm_bridge_proxy.py --bind $bridge_address --port $VLLM_SR_LITELLM_BRIDGE_PORT --target-host 127.0.0.1 --target-port ${LITELLM_PORT:-4000}
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now exocortex-vllm-sr-litellm-bridge.service

docker pull "$VLLM_SR_IMAGE"
docker pull "$VLLM_SR_ENVOY_IMAGE"
image_arch="$(docker image inspect "$VLLM_SR_IMAGE" --format '{{.Architecture}}')"
host_arch="$(uname -m)"
if [[ "$host_arch" == aarch64 && "$image_arch" != arm64 ]]; then
  echo "Image architecture $image_arch is not compatible with DGX Spark $host_arch." >&2
  exit 1
fi

if docker container inspect "$VLLM_SR_ENVOY_CONTAINER" >/dev/null 2>&1; then
  docker rm -f "$VLLM_SR_ENVOY_CONTAINER" >/dev/null
fi
if docker container inspect "$VLLM_SR_CONTAINER" >/dev/null 2>&1; then
  docker rm -f "$VLLM_SR_CONTAINER" >/dev/null
fi

docker run -d \
  --name "$VLLM_SR_CONTAINER" \
  --restart unless-stopped \
  --add-host host.docker.internal:host-gateway \
  --security-opt no-new-privileges:true \
  -p "$VLLM_SR_BIND:$VLLM_SR_MANAGEMENT_PORT:8080" \
  -v "$RUNTIME_DIR/config.yaml:/app/config.yaml:ro" \
  -v "$RUNTIME_DIR/models:/app/models" \
  "$VLLM_SR_IMAGE" >/dev/null

docker run -d \
  --name "$VLLM_SR_ENVOY_CONTAINER" \
  --restart unless-stopped \
  --user "$(id -u):$(id -g)" \
  --link "$VLLM_SR_CONTAINER:router" \
  --add-host host.docker.internal:host-gateway \
  --security-opt no-new-privileges:true \
  -p "$VLLM_SR_BIND:$VLLM_SR_PORT:8899" \
  -v "$RUNTIME_DIR/envoy.yaml:/etc/envoy/envoy.yaml:ro" \
  "$VLLM_SR_ENVOY_IMAGE" -c /etc/envoy/envoy.yaml >/dev/null

echo "vLLM Semantic Router v0.6 challenger started on $VLLM_SR_BIND:$VLLM_SR_PORT."
echo 'Production HomeBlend and Open WebUI routes were not modified.'
