#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
LEGACY_ENV_FILE="$CONFIG_DIR/bootstrap.env"

mkdir -p "$CONFIG_DIR"
if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$LEGACY_ENV_FILE" ]]; then
    cp "$LEGACY_ENV_FILE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "Migrated existing secrets to $ENV_FILE"
  else
    cp "$SCRIPT_DIR/config/stack.example.env" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    echo "Created $ENV_FILE; replace placeholder secrets before production use." >&2
  fi
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

if [[ -z "${SEARXNG_SECRET:-}" || "$SEARXNG_SECRET" == replace-with-* ]]; then
  SEARXNG_SECRET="$(openssl rand -hex 32)"
  printf 'SEARXNG_SECRET=%s\n' "$SEARXNG_SECRET" >>"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  export SEARXNG_SECRET
fi

command -v docker >/dev/null
docker info >/dev/null
docker compose version >/dev/null

docker compose \
  --env-file "$ENV_FILE" \
  --file "$SCRIPT_DIR/compose.tools.yaml" \
  up --detach --build

# Give optional local clients private container-to-container access without
# publishing vLLM, SearXNG, or MCP beyond the DGX. Existing containers are not
# recreated. DNS names become available on the user-defined tools network.
for client_container in open-webui vllm-qwen3-8b; do
  if docker container inspect "$client_container" >/dev/null 2>&1; then
    if ! docker inspect "$client_container" \
      --format '{{json .NetworkSettings.Networks}}' | grep -Fq 'exocortex-tools'; then
      docker network connect exocortex-tools "$client_container"
    fi
  fi
done

echo "Waiting for MCP gateway..."
for _ in $(seq 1 90); do
  if curl -sS -o /dev/null "http://${MCP_GATEWAY_BIND:-127.0.0.1}:${MCP_GATEWAY_PORT:-8766}/mcp"; then
    break
  fi
  sleep 2
done

curl -sS -o /dev/null "http://${MCP_GATEWAY_BIND:-127.0.0.1}:${MCP_GATEWAY_PORT:-8766}/mcp"

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
if [[ -x "$CLAUDE_BIN" ]] && ! "$CLAUDE_BIN" mcp get exocortex >/dev/null 2>&1; then
  "$CLAUDE_BIN" mcp add --transport http --scope user exocortex \
    "http://127.0.0.1:${MCP_GATEWAY_PORT:-8766}/mcp"
fi

echo "Exocortex MCP endpoint: http://${MCP_GATEWAY_BIND:-127.0.0.1}:${MCP_GATEWAY_PORT:-8766}/mcp"
echo "Claude Code registration: claude mcp add --transport http --scope user exocortex http://127.0.0.1:${MCP_GATEWAY_PORT:-8766}/mcp"
