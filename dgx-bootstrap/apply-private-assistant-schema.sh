#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
SCHEMA_FILE="${1:-$SCRIPT_DIR/../omi_homeblend/storage/001_private_assistant.sql}"

[[ -r "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 2; }
[[ -r "$SCHEMA_FILE" ]] || { echo "Missing schema: $SCHEMA_FILE" >&2; exit 2; }

"$SCRIPT_DIR/check-postgres-encryption.sh"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${POSTGRES_CONTAINER:=spark-postgres}"
: "${EXOCORTEX_DATABASE:=exocortex}"

admin_user="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^POSTGRES_USER=//p' | head -1)"
admin_user="${admin_user:-postgres}"

echo 'Encryption gate passed. Applying private-assistant schema transactionally.'
docker exec -i "$POSTGRES_CONTAINER" psql \
  --set ON_ERROR_STOP=1 \
  --username "$admin_user" \
  --dbname "$EXOCORTEX_DATABASE" <"$SCHEMA_FILE"
