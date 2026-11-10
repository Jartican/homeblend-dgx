#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/proposals/exocortex-gateway"
CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
STACK_ENV="$CONFIG_DIR/stack.env"
GATEWAY_ENV="$CONFIG_DIR/gateway.env"
INSTALL_DIR="$HOME/.local/share/exocortex-gateway"
VENV_DIR="$HOME/.local/share/exocortex-gateway-venv"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/exocortex-gateway.service"
GATEWAY_HOST="${EXOCORTEX_GATEWAY_HOST:-127.0.0.1}"
GATEWAY_PORT="${EXOCORTEX_GATEWAY_PORT:-4010}"
ALLOW_UNENCRYPTED_TEST=0
CHECK_ONLY=0

usage() {
  cat <<'EOF'
Usage: ./deploy-exocortex-gateway.sh [--check] [--allow-unencrypted-test]

By default deployment stops unless PostgreSQL storage is verified as LUKS/
dm-crypt encrypted. The override is for synthetic test prompts only.
EOF
}

while (($#)); do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --allow-unencrypted-test) ALLOW_UNENCRYPTED_TEST=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ -r "$STACK_ENV" ]] || {
  echo "Missing $STACK_ENV; run setup-postgres-pgvector.sh first." >&2
  exit 2
}

set -a
# shellcheck disable=SC1090
. "$STACK_ENV"
set +a

: "${POSTGRES_CONTAINER:=spark-postgres}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required in $STACK_ENV}"
: "${POSTGRES_PORT:=5432}"
: "${LITELLM_HOST:=127.0.0.1}"
: "${LITELLM_PORT:=4000}"
: "${LITELLM_KEY:?LITELLM_KEY is required in $STACK_ENV}"

command -v docker >/dev/null
command -v python3 >/dev/null
command -v systemctl >/dev/null
docker container inspect "$POSTGRES_CONTAINER" >/dev/null
curl -fsS -H "Authorization: Bearer $LITELLM_KEY" \
  "http://$LITELLM_HOST:$LITELLM_PORT/v1/models" >/dev/null

if "$SCRIPT_DIR/check-postgres-encryption.sh"; then
  storage_encrypted=1
else
  storage_encrypted=0
  if (( ! ALLOW_UNENCRYPTED_TEST )); then
    echo 'Deployment stopped before schema or service changes.' >&2
    echo 'Encrypt the PostgreSQL backing storage, or use --allow-unencrypted-test with synthetic data only.' >&2
    exit 1
  fi
  echo 'WARNING: proceeding with an unencrypted synthetic-data-only trial.' >&2
fi

if (( CHECK_ONLY )); then
  echo 'Gateway deployment prerequisites passed.'
  exit 0
fi

admin_user="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^POSTGRES_USER=//p' | head -1)"
admin_db="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^POSTGRES_DB=//p' | head -1)"
admin_user="${admin_user:-postgres}"
admin_db="${admin_db:-postgres}"

# Canonicalize safely: create the role/database if missing; never rename or drop
# the original database. The password is supplied as a psql variable and is not
# written into the SQL migration file.
docker exec -i "$POSTGRES_CONTAINER" psql -v ON_ERROR_STOP=1 \
  -v app_password="$POSTGRES_PASSWORD" -U "$admin_user" -d "$admin_db" <<'SQL'
SELECT format('CREATE ROLE exocortex LOGIN PASSWORD %L', :'app_password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'exocortex') \gexec
SELECT format('ALTER ROLE exocortex LOGIN PASSWORD %L', :'app_password') \gexec
SELECT 'CREATE DATABASE exocortex OWNER exocortex'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'exocortex') \gexec
SQL

docker exec -i "$POSTGRES_CONTAINER" psql -v ON_ERROR_STOP=1 \
  -U "$admin_user" -d exocortex -c 'CREATE EXTENSION IF NOT EXISTS vector;' >/dev/null

schema_present="$(docker exec "$POSTGRES_CONTAINER" psql -v ON_ERROR_STOP=1 \
  -U exocortex -d exocortex -Atc \
  "SELECT to_regclass('exocortex_raw.sessions') IS NOT NULL;")"
if [[ "$schema_present" != t ]]; then
  docker exec -i "$POSTGRES_CONTAINER" psql -v ON_ERROR_STOP=1 \
    -U exocortex -d exocortex <"$SOURCE_DIR/schema.sql"
else
  echo 'Existing exocortex_raw schema detected; preserving it.'
fi
docker exec -i "$POSTGRES_CONTAINER" psql -v ON_ERROR_STOP=1 \
  -U exocortex -d exocortex <"$SOURCE_DIR/schema-comments.sql"

mkdir -p "$CONFIG_DIR" "$INSTALL_DIR" "$SERVICE_DIR"
chmod 700 "$CONFIG_DIR"
install -m 0644 "$SOURCE_DIR/app.py" "$INSTALL_DIR/app.py"
install -m 0644 "$SOURCE_DIR/routing.yaml" "$INSTALL_DIR/routing.yaml"
install -m 0600 "$SOURCE_DIR/logging.yaml" "$INSTALL_DIR/logging.yaml"
install -m 0644 "$SOURCE_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"
install -m 0644 "$SOURCE_DIR/SCHEMA-CONTEXT.md" "$INSTALL_DIR/SCHEMA-CONTEXT.md"
install -m 0644 "$SOURCE_DIR/semantic-model.yaml" "$INSTALL_DIR/semantic-model.yaml"
install -m 0644 "$SOURCE_DIR/schema-comments.sql" "$INSTALL_DIR/schema-comments.sql"

python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --disable-pip-version-check -r "$INSTALL_DIR/requirements.txt"

umask 077
existing_gateway_key=""
if [[ -r "$GATEWAY_ENV" ]]; then
  existing_gateway_key="$(sed -n 's/^EXOCORTEX_GATEWAY_KEY=//p' "$GATEWAY_ENV" | head -1)"
fi
gateway_key="${existing_gateway_key:-$(openssl rand -hex 32)}"
encoded_postgres_password="$(python3 -c 'import os, urllib.parse; print(urllib.parse.quote(os.environ["POSTGRES_PASSWORD"], safe=""))')"
cat >"$GATEWAY_ENV" <<EOF
EXOCORTEX_ROUTING_FILE=$INSTALL_DIR/routing.yaml
EXOCORTEX_LOGGING_FILE=$INSTALL_DIR/logging.yaml
EXOCORTEX_DATABASE_URL=postgresql://exocortex:$encoded_postgres_password@127.0.0.1:$POSTGRES_PORT/exocortex
EXOCORTEX_LITELLM_URL=http://$LITELLM_HOST:$LITELLM_PORT
EXOCORTEX_LITELLM_KEY=$LITELLM_KEY
EXOCORTEX_GATEWAY_KEY=$gateway_key
EXOCORTEX_STORAGE_ENCRYPTED=$storage_encrypted
EXOCORTEX_ALLOW_UNENCRYPTED_TEST=$ALLOW_UNENCRYPTED_TEST
EOF
chmod 600 "$GATEWAY_ENV"

cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Exocortex routing and raw-session gateway
After=network-online.target litellm-qwen.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$GATEWAY_ENV
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/uvicorn app:app --host $GATEWAY_HOST --port $GATEWAY_PORT
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now exocortex-gateway.service
for _ in $(seq 1 30); do
  if curl -fsS "http://$GATEWAY_HOST:$GATEWAY_PORT/health"; then
    gateway_healthy=1
    break
  fi
  sleep 1
done
[[ "${gateway_healthy:-0}" == 1 ]] || {
  systemctl --user status exocortex-gateway.service --no-pager -l >&2 || true
  exit 1
}
echo

mkdir -p "$HOME/.local/bin" "$HOME/backups/postgres"
cat >"$HOME/.local/bin/backup-exocortex-postgres" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
backup_dir="\${EXOCORTEX_POSTGRES_BACKUP_DIR:-\$HOME/backups/postgres}"
mkdir -p "\$backup_dir"
timestamp="\$(date -u +%Y%m%dT%H%M%SZ)"
target="\$backup_dir/exocortex-\$timestamp.dump"
docker exec "$POSTGRES_CONTAINER" pg_dump -U exocortex -d exocortex -Fc >"\$target"
echo "\$target"
EOF
chmod 700 "$HOME/.local/bin/backup-exocortex-postgres"

echo "Gateway ready on http://$GATEWAY_HOST:$GATEWAY_PORT"
echo "Protected client key: $GATEWAY_ENV (EXOCORTEX_GATEWAY_KEY)"
