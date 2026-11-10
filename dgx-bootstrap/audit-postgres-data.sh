#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
STACK_ENV="$CONFIG_DIR/stack.env"
[[ -r "$STACK_ENV" ]] || { echo "Missing $STACK_ENV" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
. "$STACK_ENV"
set +a

: "${POSTGRES_CONTAINER:=spark-postgres}"

admin_user="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^POSTGRES_USER=//p' | head -1)"
admin_db="$(docker inspect "$POSTGRES_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^POSTGRES_DB=//p' | head -1)"
admin_user="${admin_user:-postgres}"
admin_db="${admin_db:-postgres}"

echo '=== Database sizes ==='
docker exec "$POSTGRES_CONTAINER" psql -U "$admin_user" -d "$admin_db" -P pager=off -c \
  "SELECT datname AS database,
          pg_size_pretty(pg_database_size(datname)) AS size
     FROM pg_database
    WHERE datallowconn
    ORDER BY pg_database_size(datname) DESC, datname;"

mapfile -t databases < <(docker exec "$POSTGRES_CONTAINER" psql -U "$admin_user" -d "$admin_db" -Atc \
  "SELECT datname FROM pg_database
    WHERE datallowconn AND NOT datistemplate
    ORDER BY datname;")

for database in "${databases[@]}"; do
  echo
  echo "=== $database: user relations ==="
  docker exec "$POSTGRES_CONTAINER" psql -U "$admin_user" -d "$database" -P pager=off -c \
    "SELECT schemaname AS schema,
            relname AS relation,
            'table' AS kind,
            pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
            n_live_tup AS estimated_rows
       FROM pg_stat_user_tables
      UNION ALL
     SELECT schemaname, viewname, 'view', NULL, NULL
       FROM pg_views
      WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
      ORDER BY 1, 2;"
done

echo
echo 'Note: estimated_rows comes from PostgreSQL statistics and may lag exact counts.'
