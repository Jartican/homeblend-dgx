#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
ENCRYPTED_MOUNT="${EXOCORTEX_ENCRYPTED_MOUNT:-/srv/exocortex/postgres}"

[[ -r "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 2; }
"$SCRIPT_DIR/check-postgres-encryption.sh"
findmnt -n "$ENCRYPTED_MOUNT" >/dev/null || {
  echo "Encrypted mount is not active: $ENCRYPTED_MOUNT" >&2
  exit 1
}

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
: "${POSTGRES_CONTAINER:=spark-postgres}"

admin_user="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^POSTGRES_USER=//p' | head -1)"
admin_user="${admin_user:-postgres}"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_root="$ENCRYPTED_MOUNT/backups/$timestamp"
install -d -m 0700 "$backup_root"

docker exec "$POSTGRES_CONTAINER" pg_dumpall -U "$admin_user" --globals-only \
  >"$backup_root/globals.sql"

mapfile -t databases < <(docker exec "$POSTGRES_CONTAINER" psql -U "$admin_user" -d postgres -Atc \
  "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname")

for database in "${databases[@]}"; do
  [[ "$database" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    echo "Unsupported database name for safe backup path: $database" >&2
    exit 1
  }
  target="$backup_root/$database.dump"
  docker exec "$POSTGRES_CONTAINER" pg_dump -U "$admin_user" -d "$database" -Fc >"$target"
  docker exec -i "$POSTGRES_CONTAINER" pg_restore --list <"$target" >/dev/null
done

(
  cd "$backup_root"
  sha256sum globals.sql ./*.dump >SHA256SUMS
  sha256sum --check SHA256SUMS >/dev/null
)

chmod -R go-rwx "$backup_root"
echo "BACKUP_VERIFIED=$backup_root"
