#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
[[ -f "$ENV_FILE" ]] || {
  echo "Missing $ENV_FILE; run setup-postgres-pgvector.sh first." >&2
  exit 1
}
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${OPEN_WEBUI_IMAGE:=ghcr.io/open-webui/open-webui@sha256:2391dd9495ec87257a200e70e66a4a77adc2d3a7fe15c07293078fb0c6a009c1}"
: "${OPEN_WEBUI_CONTAINER:=open-webui}"
: "${OPEN_WEBUI_BIND:=127.0.0.1}"
: "${OPEN_WEBUI_PORT:=12000}"
: "${OPEN_WEBUI_SECRET_KEY:?OPEN_WEBUI_SECRET_KEY is required in $ENV_FILE}"
: "${OPEN_WEBUI_NETWORK:=exocortex-tools}"
: "${OPEN_WEBUI_OPENAI_BASE_URL:=http://vllm-qwen3-8b:8000/v1}"
: "${OPEN_WEBUI_OPENAI_KEY:=local-vllm}"
: "${OPEN_WEBUI_MCP_URL:=http://exocortex-mcp-gateway:8000/mcp}"
: "${OPEN_WEBUI_ENABLE_OLLAMA_API:=false}"

docker network inspect "$OPEN_WEBUI_NETWORK" >/dev/null 2>&1 || {
  echo "Missing Docker network $OPEN_WEBUI_NETWORK; run setup-tools-mcp.sh first." >&2
  exit 1
}

tool_server_connections="$(cat <<EOF
[{"type":"mcp","url":"$OPEN_WEBUI_MCP_URL","spec_type":"url","spec":"","path":"","auth_type":"none","key":"","config":{"enable":true,"function_name_filter_list":"","access_grants":[]},"info":{"id":"exocortex","name":"Exocortex","description":"Private Exocortex search and memory tools"}}]
EOF
)"

if docker container inspect "$OPEN_WEBUI_CONTAINER" >/dev/null 2>&1; then
  echo "Using existing container: $OPEN_WEBUI_CONTAINER"
  docker update --restart unless-stopped "$OPEN_WEBUI_CONTAINER" >/dev/null
  if ! docker inspect "$OPEN_WEBUI_CONTAINER" \
      --format '{{json .NetworkSettings.Networks}}' | grep -Fq "\"$OPEN_WEBUI_NETWORK\""; then
    docker network connect "$OPEN_WEBUI_NETWORK" "$OPEN_WEBUI_CONTAINER"
  fi
  docker start "$OPEN_WEBUI_CONTAINER" >/dev/null

  existing_env="$(docker inspect "$OPEN_WEBUI_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}')"
  for required_name in WEBUI_SECRET_KEY OPENAI_API_BASE_URLS TOOL_SERVER_CONNECTIONS; do
    if ! grep -q "^${required_name}=" <<<"$existing_env"; then
      echo "Notice: existing $OPEN_WEBUI_CONTAINER predates declarative $required_name; preserving its persistent database configuration."
    fi
  done
else
  docker run -d \
    --name "$OPEN_WEBUI_CONTAINER" \
    --restart unless-stopped \
    --network "$OPEN_WEBUI_NETWORK" \
    --add-host host.docker.internal:host-gateway \
    -e "WEBUI_SECRET_KEY=$OPEN_WEBUI_SECRET_KEY" \
    -e ENABLE_PERSISTENT_CONFIG=true \
    -e ENABLE_OPENAI_API=true \
    -e "OPENAI_API_BASE_URLS=$OPEN_WEBUI_OPENAI_BASE_URL" \
    -e "OPENAI_API_KEYS=$OPEN_WEBUI_OPENAI_KEY" \
    -e "TOOL_SERVER_CONNECTIONS=$tool_server_connections" \
    -e "ENABLE_OLLAMA_API=$OPEN_WEBUI_ENABLE_OLLAMA_API" \
    -e ANONYMIZED_TELEMETRY=false \
    -e DO_NOT_TRACK=true \
    -p "$OPEN_WEBUI_BIND:$OPEN_WEBUI_PORT:8080" \
    -v open-webui:/app/backend/data \
    "$OPEN_WEBUI_IMAGE" >/dev/null
fi

echo 'Waiting for Open WebUI...'
for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:$OPEN_WEBUI_PORT/" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS "http://127.0.0.1:$OPEN_WEBUI_PORT/" >/dev/null

docker exec -e TARGET_URL="$OPEN_WEBUI_OPENAI_BASE_URL" "$OPEN_WEBUI_CONTAINER" python -c \
  'import os, socket; from urllib.parse import urlparse; u=urlparse(os.environ["TARGET_URL"]); socket.create_connection((u.hostname, u.port or 80), 10).close()'
docker exec -e TARGET_URL="$OPEN_WEBUI_MCP_URL" "$OPEN_WEBUI_CONTAINER" python -c \
  'import os, socket; from urllib.parse import urlparse; u=urlparse(os.environ["TARGET_URL"]); socket.create_connection((u.hostname, u.port or 80), 10).close()'

echo "Open WebUI ready on $OPEN_WEBUI_BIND:$OPEN_WEBUI_PORT"
echo "Fast model connection: $OPEN_WEBUI_OPENAI_BASE_URL"
echo "Exocortex MCP connection: $OPEN_WEBUI_MCP_URL"
echo "Tailnet publishing command: sudo tailscale serve --bg $OPEN_WEBUI_PORT"
