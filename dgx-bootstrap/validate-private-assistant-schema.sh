#!/usr/bin/env bash
set -Eeuo pipefail

SCHEMA_FILE="${1:-/tmp/001_private_assistant.sql}"
[[ -r "$SCHEMA_FILE" ]] || { echo "Missing schema: $SCHEMA_FILE" >&2; exit 2; }

image="$(docker inspect spark-postgres --format '{{.Config.Image}}')"
name="homeblend-schema-check-${BASHPID}"
label='com.homeblend.purpose=schema-validation'

cleanup() {
  if [[ "$(docker inspect "$name" --format '{{index .Config.Labels "com.homeblend.purpose"}}' 2>/dev/null || true)" == schema-validation ]]; then
    docker rm -f "$name" >/dev/null
  fi
}
trap cleanup EXIT

docker run --rm -d \
  --name "$name" \
  --label "$label" \
  --tmpfs /var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=test-only-password \
  "$image" >/dev/null

ready=false
for _ in {1..30}; do
  if docker exec "$name" pg_isready -U postgres >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == true ]] || { echo 'Temporary PostgreSQL did not become ready' >&2; exit 1; }

docker exec -i "$name" psql -U postgres -d postgres \
  --set ON_ERROR_STOP=1 <"$SCHEMA_FILE" >/dev/null

table_count="$(docker exec "$name" psql -U postgres -d postgres -Atc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='homeblend_voice'")"
[[ "$table_count" == 7 ]] || {
  echo "Expected 7 schema tables, found $table_count" >&2
  exit 1
}

echo 'SCHEMA_VALIDATION=passed-tmpfs'
