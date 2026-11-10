#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"

[[ -r "$ENV_FILE" ]] || {
  echo "Missing $ENV_FILE" >&2
  exit 2
}

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${POSTGRES_CONTAINER:=spark-postgres}"
: "${POSTGRES_DATA_DIR:=$HOME/postgres_data}"

if docker container inspect "$POSTGRES_CONTAINER" >/dev/null 2>&1; then
  mounted_data_dir="$(docker inspect "$POSTGRES_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}')"
  POSTGRES_DATA_DIR="${mounted_data_dir:-$POSTGRES_DATA_DIR}"
fi

resolved_data_dir="$(readlink -f "$POSTGRES_DATA_DIR")"
mount_source="$(findmnt -n -o SOURCE -T "$resolved_data_dir")"
mount_target="$(findmnt -n -o TARGET -T "$resolved_data_dir")"

echo "PostgreSQL data: $resolved_data_dir"
echo "Backing mount: $mount_source on $mount_target"

if [[ "$mount_source" == /dev/* ]] && lsblk -s -n -o TYPE "$mount_source" | grep -qx crypt; then
  echo 'ENCRYPTED_AT_REST=yes (dm-crypt/LUKS detected in the backing-device chain)'
  exit 0
fi

echo 'ENCRYPTED_AT_REST=no-or-unverified'
echo 'Raw conversation and exact-location logging should remain disabled.' >&2
exit 1
