#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

echo '=== Ollama ==='
MODEL_QUALITY="${MODEL_QUALITY:-${MODEL:-qwen3.8:27b}}"
MODEL_FAST_ALIAS="${MODEL_FAST_ALIAS:-exocortex-chat-fast}"
MODEL_QUALITY_ALIAS="${MODEL_QUALITY_ALIAS:-exocortex-agent-quality}"
curl -fsS "$OLLAMA_URL/api/tags" | grep -F "\"name\":\"$MODEL_QUALITY\"" >/dev/null
echo "$MODEL_QUALITY available"

echo '=== vLLM fast chat/tool model ==='
curl -fsS "http://${VLLM_BIND:-127.0.0.1}:${VLLM_PORT:-8001}/health" >/dev/null
curl -fsS "http://${VLLM_BIND:-127.0.0.1}:${VLLM_PORT:-8001}/v1/models" \
  | grep -F "$MODEL_FAST_ALIAS" >/dev/null
echo "$MODEL_FAST_ALIAS available on ${VLLM_BIND:-127.0.0.1}:${VLLM_PORT:-8001}"

echo '=== LiteLLM ==='
systemctl --user is-active litellm-qwen.service
curl -fsS -H "Authorization: Bearer $LITELLM_KEY" \
  "http://$LITELLM_HOST:$LITELLM_PORT/v1/models" >/dev/null
echo "localhost:$LITELLM_PORT healthy"
routes="$(curl -fsS -H "Authorization: Bearer $LITELLM_KEY" \
  "http://$LITELLM_HOST:$LITELLM_PORT/v1/models")"
grep -F "$MODEL_FAST_ALIAS" <<<"$routes" >/dev/null
grep -F "$MODEL_QUALITY_ALIAS" <<<"$routes" >/dev/null
echo "routes: $MODEL_FAST_ALIAS, $MODEL_QUALITY_ALIAS"

echo '=== Postgres and pgvector ==='
container_user="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^POSTGRES_USER=//p' | head -1)"
container_db="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^POSTGRES_DB=//p' | head -1)"
container_user="${container_user:-postgres}"
container_db="${container_db:-postgres}"
docker exec "$POSTGRES_CONTAINER" pg_isready -U "$container_user" -d "$container_db"
vector_version="$(docker exec "$POSTGRES_CONTAINER" psql -U "$container_user" -d "$container_db" -Atc \
  "select extversion from pg_extension where extname='vector';")"
[[ -n "$vector_version" ]]
echo "database=$container_db pgvector=$vector_version"

if [[ "${DEPLOY_EXOCORTEX_GATEWAY:-0}" == 1 ]]; then
  echo '=== PostgreSQL storage encryption ==='
  if ! "$SCRIPT_DIR/check-postgres-encryption.sh"; then
    gateway_env="$CONFIG_DIR/gateway.env"
    if [[ -r "$gateway_env" ]] && grep -qx 'EXOCORTEX_ALLOW_UNENCRYPTED_TEST=1' "$gateway_env"; then
      echo 'WARNING: accepted only because the gateway is marked synthetic-data-only.' >&2
    else
      exit 1
    fi
  fi

  echo '=== Exocortex routing/logging gateway ==='
  systemctl --user is-active exocortex-gateway.service
  curl -fsS "http://${EXOCORTEX_GATEWAY_HOST:-127.0.0.1}:${EXOCORTEX_GATEWAY_PORT:-4010}/health"
  schema_ready="$(docker exec "$POSTGRES_CONTAINER" psql -U exocortex -d exocortex -Atc \
    "SELECT to_regclass('exocortex_raw.full_turn_context') IS NOT NULL;")"
  [[ "$schema_ready" == t ]]
  schema_comment="$(docker exec "$POSTGRES_CONTAINER" psql -U exocortex -d exocortex -Atc \
    "SELECT obj_description('exocortex_raw.sessions'::regclass);")"
  [[ "$schema_comment" == *'Grain: one logical conversation session'* ]]
  echo 'exocortex_raw schema and introspection comments available'
fi

echo '=== Open WebUI ==='
OPEN_WEBUI_CONTAINER="${OPEN_WEBUI_CONTAINER:-open-webui}"
curl -fsS "http://${OPEN_WEBUI_BIND:-127.0.0.1}:$OPEN_WEBUI_PORT/" >/dev/null
docker exec -e TARGET_URL="${OPEN_WEBUI_OPENAI_BASE_URL:-http://vllm-qwen3-8b:8000/v1}" \
  "$OPEN_WEBUI_CONTAINER" python -c \
  'import os, socket; from urllib.parse import urlparse; u=urlparse(os.environ["TARGET_URL"]); socket.create_connection((u.hostname, u.port or 80), 10).close()'
docker exec -e TARGET_URL="${OPEN_WEBUI_MCP_URL:-http://exocortex-mcp-gateway:8000/mcp}" \
  "$OPEN_WEBUI_CONTAINER" python -c \
  'import os, socket; from urllib.parse import urlparse; u=urlparse(os.environ["TARGET_URL"]); socket.create_connection((u.hostname, u.port or 80), 10).close()'
echo "${OPEN_WEBUI_BIND:-127.0.0.1}:$OPEN_WEBUI_PORT healthy with model and MCP network access"

echo '=== Shared MCP tools ==='
SEARXNG_CONTAINER="${SEARXNG_CONTAINER:-exocortex-searxng}"
MCP_GATEWAY_CONTAINER="${MCP_GATEWAY_CONTAINER:-exocortex-mcp-gateway}"
docker inspect "$SEARXNG_CONTAINER" "$MCP_GATEWAY_CONTAINER" >/dev/null
[[ "$(docker inspect "$SEARXNG_CONTAINER" --format '{{.State.Health.Status}}')" == healthy ]]
[[ "$(docker inspect "$MCP_GATEWAY_CONTAINER" --format '{{.State.Health.Status}}')" == healthy ]]
curl -sS -o /dev/null "http://127.0.0.1:${MCP_GATEWAY_PORT:-8766}/mcp"
echo "localhost:${MCP_GATEWAY_PORT:-8766}/mcp reachable"

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
if [[ -x "$CLAUDE_BIN" ]]; then
  "$CLAUDE_BIN" mcp get exocortex >/dev/null
  echo 'Claude MCP registration: exocortex'
fi

if [[ "${DEPLOY_PRIVATE_VOICE_STACK:-1}" == 1 ]]; then
  echo '=== Private Voice Core ==='
  voice_health="$(curl -fsS "http://127.0.0.1:${VOICE_GATEWAY_PORT:-8791}/health")"
  python3 -c '
import json, sys
health = json.load(sys.stdin)
assert health.get("status") == "ok"
assert health.get("raw_audio_persistence") is False
app_auth = health.get("security", {}).get("application_auth", {})
assert app_auth.get("http_routes_protected") is True
assert app_auth.get("compatibility_bridge") is False
assert app_auth.get("mode") in {"not_enrolled", "registry"}
if app_auth.get("mode") == "registry":
    assert app_auth.get("registry_status") == "valid"
    assert app_auth.get("production_ready") is True
print("application auth mode=" + app_auth["mode"])
' <<<"$voice_health"
  for container in \
    "${SPEACHES_CONTAINER:-exocortex-speaches}" \
    "${VOICE_GATEWAY_CONTAINER:-exocortex-voice-gateway}" \
    "${NEURAL_WAKE_CONTAINER:-exocortex-neural-wake}" \
    "${DENOISER_CONTAINER:-exocortex-denoiser}"; do
    [[ "$(docker inspect "$container" --format '{{.State.Health.Status}}')" == healthy ]]
  done
  if [[ "${DEPLOY_SPEAKER_AWARENESS:-0}" == 1 ]]; then
    [[ "$(docker inspect "${SPEAKER_CONTAINER:-exocortex-speaker-verifier}" \
      --format '{{.State.Health.Status}}')" == healthy ]]
  fi
  if [[ "${DEPLOY_SORTFORMER_DIARIZATION:-0}" == 1 ]]; then
    [[ "$(docker inspect "${DIARIZATION_CONTAINER:-exocortex-diarization}" \
      --format '{{.State.Health.Status}}')" == healthy ]]
  fi
  serve_status="$(tailscale serve status 2>/dev/null || true)"
  if grep -Fq '/voice' <<<"$serve_status"; then
    grep -Fq '(tailnet only)' <<<"$serve_status"
    python3 -c '
import json, sys
state = json.load(sys.stdin)["security"]["application_auth"]
assert state.get("production_ready") is True
' <<<"$voice_health"
    echo 'Tailnet /voice route is published with production application auth.'
  else
    echo 'Voice Core is loopback-only pending signed-phone enrollment.'
  fi
fi

echo '=== Tailscale ==='
tailscale status --self
tailscale serve status || true

echo '=== Latest database backup ==='
latest_backup="$(find "$HOME/backups/postgres" -maxdepth 1 -type f -name '*.dump' -printf '%T@ %p\n' \
  | sort -nr | head -1 | cut -d' ' -f2-)"
if [[ -n "$latest_backup" ]]; then
  docker exec -i "$POSTGRES_CONTAINER" pg_restore --list <"$latest_backup" >/dev/null
  echo "$latest_backup (valid archive)"
else
  echo 'No backup found yet.'
fi

echo '=== Relevant listeners ==='
ss -ltn | grep -E ':(4000|4010|5432|8001|8765|8766|11434|12000)[[:space:]]' || true
