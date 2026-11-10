#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
LEGACY_ENV_FILE="$CONFIG_DIR/bootstrap.env"
mkdir -p "$CONFIG_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$LEGACY_ENV_FILE" ]]; then
    cp "$LEGACY_ENV_FILE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  else
  umask 077
  postgres_password="$(openssl rand -hex 24)"
  litellm_key="sk-local-$(openssl rand -hex 24)"
  open_webui_secret="$(openssl rand -hex 32)"
  searxng_secret="$(openssl rand -hex 32)"
  cat >"$ENV_FILE" <<EOF
MODEL_QUALITY=qwen3.8:27b
MODEL_FAST_SOURCE=nvidia/Qwen3-8B-NVFP4
MODEL_FAST_ALIAS=exocortex-chat-fast
MODEL_QUALITY_ALIAS=exocortex-agent-quality
CONTEXT_TOKENS=262144
OLLAMA_URL=http://127.0.0.1:11434
LITELLM_HOST=127.0.0.1
LITELLM_PORT=4000
LITELLM_KEY=$litellm_key
LITELLM_VERSION=1.98.0
POSTGRES_IMAGE=pgvector/pgvector@sha256:ccc6e83d6e35e931dc7c5def2022729d5a6c370318d099181995567ff1fb4d6b
POSTGRES_CONTAINER=spark-postgres
POSTGRES_DB=exocortex
POSTGRES_USER=exocortex
POSTGRES_PASSWORD=$postgres_password
POSTGRES_DATA_DIR=$HOME/postgres_data
POSTGRES_BIND=127.0.0.1
POSTGRES_PORT=5432
DEPLOY_EXOCORTEX_GATEWAY=1
REQUIRE_ENCRYPTED_POSTGRES=1
ALLOW_UNENCRYPTED_GATEWAY_TEST=0
EXOCORTEX_GATEWAY_HOST=127.0.0.1
EXOCORTEX_GATEWAY_PORT=4010
OPEN_WEBUI_IMAGE=ghcr.io/open-webui/open-webui@sha256:2391dd9495ec87257a200e70e66a4a77adc2d3a7fe15c07293078fb0c6a009c1
OPEN_WEBUI_CONTAINER=open-webui
OPEN_WEBUI_BIND=127.0.0.1
OPEN_WEBUI_PORT=12000
OPEN_WEBUI_SECRET_KEY=$open_webui_secret
OPEN_WEBUI_NETWORK=exocortex-tools
OPEN_WEBUI_OPENAI_BASE_URL=http://vllm-qwen3-8b:8000/v1
OPEN_WEBUI_OPENAI_KEY=local-vllm
OPEN_WEBUI_MCP_URL=http://exocortex-mcp-gateway:8000/mcp
OPEN_WEBUI_ENABLE_OLLAMA_API=false
MCP_GATEWAY_IMAGE=exocortex/mcp-gateway:local
MCP_GATEWAY_BIND=127.0.0.1
MCP_GATEWAY_PORT=8766
MCP_GATEWAY_CONTAINER=exocortex-mcp-gateway
SEARXNG_IMAGE=ghcr.io/searxng/searxng@sha256:11a9b34cdc0b1ec2b991470a2762ecb5a1a531898289fb51dcd015260450729e
SEARXNG_CONTAINER=exocortex-searxng
SEARXNG_SECRET=$searxng_secret
VLLM_IMAGE=vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967
VLLM_CONTAINER=vllm-qwen3-8b
VLLM_MODEL_SOURCE=nvidia/Qwen3-8B-NVFP4
VLLM_SERVED_MODEL=exocortex-chat-fast
VLLM_BIND=127.0.0.1
VLLM_PORT=8001
VLLM_MAX_MODEL_LEN=32768
VLLM_GPU_MEMORY_UTILIZATION=0.25
VLLM_URL=http://127.0.0.1:8001/v1
EOF
  fi
  echo "Created protected configuration: $ENV_FILE"
fi
chmod 600 "$ENV_FILE"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

write_env_value() {
  local key="$1" value="$2" temp_env
  temp_env="$(mktemp "$CONFIG_DIR/stack.env.XXXXXX")"
  awk -F= -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $1 == key { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$ENV_FILE" >"$temp_env"
  chmod 600 "$temp_env"
  mv -f "$temp_env" "$ENV_FILE"
  printf -v "$key" '%s' "$value"
  export "$key"
}

if [[ -z "${POSTGRES_PASSWORD:-}" || "$POSTGRES_PASSWORD" == replace-with-* ]]; then
  write_env_value POSTGRES_PASSWORD "$(openssl rand -hex 24)"
fi
if [[ -z "${LITELLM_KEY:-}" || "$LITELLM_KEY" == replace-with-* ]]; then
  write_env_value LITELLM_KEY "sk-local-$(openssl rand -hex 24)"
fi
if [[ -z "${OPEN_WEBUI_SECRET_KEY:-}" || "$OPEN_WEBUI_SECRET_KEY" == replace-with-* ]]; then
  write_env_value OPEN_WEBUI_SECRET_KEY "$(openssl rand -hex 32)"
fi
if [[ -z "${SEARXNG_SECRET:-}" || "$SEARXNG_SECRET" == replace-with-* ]]; then
  write_env_value SEARXNG_SECRET "$(openssl rand -hex 32)"
fi

: "${POSTGRES_IMAGE:=pgvector/pgvector@sha256:ccc6e83d6e35e931dc7c5def2022729d5a6c370318d099181995567ff1fb4d6b}"
: "${POSTGRES_CONTAINER:=spark-postgres}"
: "${POSTGRES_DB:=exocortex}"
: "${POSTGRES_USER:=exocortex}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required in $ENV_FILE}"
: "${POSTGRES_DATA_DIR:=$HOME/postgres_data}"
: "${POSTGRES_BIND:=127.0.0.1}"
: "${POSTGRES_PORT:=5432}"

command -v docker >/dev/null || {
  echo 'Docker is required. Run the privileged bootstrap stage first.' >&2
  exit 1
}

if docker container inspect "$POSTGRES_CONTAINER" >/dev/null 2>&1; then
  echo "Using existing container: $POSTGRES_CONTAINER"
  docker update --restart always "$POSTGRES_CONTAINER" >/dev/null
  docker start "$POSTGRES_CONTAINER" >/dev/null

  existing_user="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | sed -n 's/^POSTGRES_USER=//p' | head -1)"
  existing_db="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | sed -n 's/^POSTGRES_DB=//p' | head -1)"
  existing_password="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | sed -n 's/^POSTGRES_PASSWORD=//p' | head -1)"
  existing_data_dir="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}')"
  existing_binding="$(docker port "$POSTGRES_CONTAINER" 5432/tcp 2>/dev/null | head -1)"

  POSTGRES_USER="${existing_user:-postgres}"
  POSTGRES_DB="${existing_db:-postgres}"
  POSTGRES_PASSWORD="${existing_password:-$POSTGRES_PASSWORD}"
  POSTGRES_DATA_DIR="${existing_data_dir:-$POSTGRES_DATA_DIR}"
  if [[ "$existing_binding" == *:* ]]; then
    POSTGRES_BIND="${existing_binding%:*}"
    POSTGRES_PORT="${existing_binding##*:}"
  fi

  temp_env="$(mktemp "$CONFIG_DIR/stack.env.XXXXXX")"
  grep -v '^POSTGRES_' "$ENV_FILE" >"$temp_env"
  {
    printf 'POSTGRES_IMAGE=%q\n' "$POSTGRES_IMAGE"
    printf 'POSTGRES_CONTAINER=%q\n' "$POSTGRES_CONTAINER"
    printf 'POSTGRES_DB=%q\n' "$POSTGRES_DB"
    printf 'POSTGRES_USER=%q\n' "$POSTGRES_USER"
    printf 'POSTGRES_PASSWORD=%q\n' "$POSTGRES_PASSWORD"
    printf 'POSTGRES_DATA_DIR=%q\n' "$POSTGRES_DATA_DIR"
    printf 'POSTGRES_BIND=%q\n' "$POSTGRES_BIND"
    printf 'POSTGRES_PORT=%q\n' "$POSTGRES_PORT"
  } >>"$temp_env"
  chmod 600 "$temp_env"
  mv -f "$temp_env" "$ENV_FILE"
else
  mkdir -p "$POSTGRES_DATA_DIR"
  docker run -d \
    --name "$POSTGRES_CONTAINER" \
    --restart always \
    -e "POSTGRES_DB=$POSTGRES_DB" \
    -e "POSTGRES_USER=$POSTGRES_USER" \
    -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    -v "$POSTGRES_DATA_DIR:/var/lib/postgresql/data" \
    -p "$POSTGRES_BIND:$POSTGRES_PORT:5432" \
    "$POSTGRES_IMAGE" >/dev/null
fi

container_user="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^POSTGRES_USER=//p' | head -1)"
container_db="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^POSTGRES_DB=//p' | head -1)"
container_user="${container_user:-postgres}"
container_db="${container_db:-postgres}"

echo 'Waiting for Postgres...'
for _ in $(seq 1 60); do
  if docker exec "$POSTGRES_CONTAINER" pg_isready -U "$container_user" -d "$container_db" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec "$POSTGRES_CONTAINER" pg_isready -U "$container_user" -d "$container_db" >/dev/null
docker exec "$POSTGRES_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$container_user" -d "$container_db" \
  -c 'CREATE EXTENSION IF NOT EXISTS vector;' >/dev/null

mkdir -p "$HOME/.local/bin" "$HOME/backups/postgres"
cat >"$HOME/.local/bin/backup-exocortex-postgres" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
backup_dir="\${EXOCORTEX_POSTGRES_BACKUP_DIR:-\$HOME/backups/postgres}"
mkdir -p "\$backup_dir"
timestamp="\$(date -u +%Y%m%dT%H%M%SZ)"
docker exec "$POSTGRES_CONTAINER" pg_dump -U "$container_user" -d "$container_db" -Fc \
  >"\$backup_dir/${container_db}-\$timestamp.dump"
echo "\$backup_dir/${container_db}-\$timestamp.dump"
EOF
chmod 700 "$HOME/.local/bin/backup-exocortex-postgres"

echo "Postgres ready: container=$POSTGRES_CONTAINER database=$container_db"
echo "pgvector: $(docker exec "$POSTGRES_CONTAINER" psql -U "$container_user" -d "$container_db" -Atc "select extversion from pg_extension where extname='vector';")"
echo "Binding: $POSTGRES_BIND:$POSTGRES_PORT"
echo 'Backup command: backup-exocortex-postgres'
