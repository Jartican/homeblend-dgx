#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${1:-}"
ENCRYPTED_MOUNT="${EXOCORTEX_ENCRYPTED_MOUNT:-/srv/exocortex/postgres}"

[[ -n "$BACKUP_DIR" ]] || { echo 'Usage: restore-drill-postgres.sh BACKUP_DIR' >&2; exit 2; }
BACKUP_DIR="$(readlink -f "$BACKUP_DIR")"
case "$BACKUP_DIR" in
  "$ENCRYPTED_MOUNT"/backups/*) ;;
  *) echo "Backup must be beneath $ENCRYPTED_MOUNT/backups" >&2; exit 2 ;;
esac
[[ -r "$BACKUP_DIR/SHA256SUMS" ]] || { echo 'Missing SHA256SUMS.' >&2; exit 2; }

"$SCRIPT_DIR/check-postgres-encryption.sh"
(
  cd "$BACKUP_DIR"
  sha256sum --check SHA256SUMS
)

: "${POSTGRES_CONTAINER:=spark-postgres}"
image="$(docker inspect "$POSTGRES_CONTAINER" --format '{{.Config.Image}}')"
name="homeblend-restore-drill-${BASHPID}"
label='com.homeblend.purpose=postgres-restore-drill'

cleanup() {
  if [[ "$(docker inspect "$name" --format '{{index .Config.Labels "com.homeblend.purpose"}}' 2>/dev/null || true)" == postgres-restore-drill ]]; then
    docker rm -f "$name" >/dev/null
  fi
}
trap cleanup EXIT

docker run --rm -d \
  --name "$name" \
  --label "$label" \
  --network none \
  --tmpfs /var/lib/postgresql/data \
  --mount "type=bind,src=$BACKUP_DIR,dst=/backups,readonly" \
  -e POSTGRES_PASSWORD=restore-drill-only \
  "$image" >/dev/null

ready=false
for _ in {1..60}; do
  if docker exec "$name" pg_isready -U postgres >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == true ]] || { echo 'Restore-drill PostgreSQL did not become ready.' >&2; exit 1; }

restored=0
for archive in "$BACKUP_DIR"/*.dump; do
  [[ -e "$archive" ]] || continue
  database="$(basename "$archive" .dump)"
  [[ "$database" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "Unsafe archive name: $database" >&2; exit 1; }
  drill_database="drill_${database//[^A-Za-z0-9_]/_}"
  docker exec "$name" createdb -U postgres "$drill_database"
  docker exec -u 0 "$name" pg_restore \
    -U postgres -d "$drill_database" --no-owner --no-privileges "/backups/$(basename "$archive")"
  docker exec "$name" psql -U postgres -d "$drill_database" -Atc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')" \
    >/dev/null
  restored=$((restored + 1))
done

((restored > 0)) || { echo 'No database archives were restored.' >&2; exit 1; }
echo "RESTORE_DRILL=passed databases=$restored"
