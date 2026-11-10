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
: "${EXOCORTEX_ENCRYPTED_MOUNT:=/srv/exocortex/postgres}"
: "${EXOCORTEX_LUKS_CONTAINER:=/var/lib/exocortex-secure/postgres.luks}"
: "${EXOCORTEX_MIN_FREE_GIB:=80}"

failures=0
warn() { printf 'WARN: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
pass() { printf 'PASS: %s\n' "$*"; }

for command in docker findmnt lsblk readlink df awk stat; do
  command -v "$command" >/dev/null 2>&1 || fail "missing required command: $command"
done

if ((failures > 0)); then
  exit 1
fi

resolved_data_dir="$(readlink -f "$POSTGRES_DATA_DIR")"
[[ -d "$resolved_data_dir" ]] || fail "PGDATA directory does not exist: $resolved_data_dir"

if docker container inspect "$POSTGRES_CONTAINER" >/dev/null 2>&1; then
  mounted_data_dir="$(docker inspect "$POSTGRES_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}')"
  if [[ -n "$mounted_data_dir" ]]; then
    resolved_data_dir="$(readlink -f "$mounted_data_dir")"
  fi
  pass "PostgreSQL container exists: $POSTGRES_CONTAINER"
else
  fail "PostgreSQL container not found: $POSTGRES_CONTAINER"
fi

mount_source="$(findmnt -n -o SOURCE -T "$resolved_data_dir")"
mount_target="$(findmnt -n -o TARGET -T "$resolved_data_dir")"
printf 'PGDATA=%s\nBACKING_SOURCE=%s\nBACKING_TARGET=%s\n' \
  "$resolved_data_dir" "$mount_source" "$mount_target"

if [[ "$mount_source" == /dev/* ]] && lsblk -s -n -o TYPE "$mount_source" | grep -qx crypt; then
  pass 'current PGDATA already has dm-crypt/LUKS in its backing-device chain'
else
  warn 'current PGDATA is not verified encrypted; persistence must remain gated'
fi

free_kib="$(df -Pk "$resolved_data_dir" | awk 'NR==2 {print $4}')"
required_kib=$((EXOCORTEX_MIN_FREE_GIB * 1024 * 1024))
if ((free_kib >= required_kib)); then
  pass "at least ${EXOCORTEX_MIN_FREE_GIB} GiB is free on the container-file filesystem"
else
  fail "less than ${EXOCORTEX_MIN_FREE_GIB} GiB is free"
fi

if [[ -e "$EXOCORTEX_LUKS_CONTAINER" ]]; then
  warn "target container already exists: $EXOCORTEX_LUKS_CONTAINER"
else
  pass 'target LUKS container path is unused'
fi

if findmnt -n "$EXOCORTEX_ENCRYPTED_MOUNT" >/dev/null 2>&1; then
  warn "target mount is already active: $EXOCORTEX_ENCRYPTED_MOUNT"
elif [[ -e "$EXOCORTEX_ENCRYPTED_MOUNT" ]] && \
     [[ -n "$(find "$EXOCORTEX_ENCRYPTED_MOUNT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
  fail "target mount directory exists and is not empty: $EXOCORTEX_ENCRYPTED_MOUNT"
else
  pass 'target encrypted mount is unused or empty'
fi

owner_mode="$(stat -c '%u:%g %a' "$resolved_data_dir")"
printf 'PGDATA_OWNER_MODE=%s\n' "$owner_mode"

tpm_output="$(systemd-cryptenroll --tpm2-device=list 2>&1 || true)"
if grep -Eq '/dev/tpm(rm)?[0-9]+' <<<"$tpm_output"; then
  warn 'a TPM2 device is available; unlock design should be reviewed before migration'
else
  pass 'no TPM2 device detected; manual passphrase unlock remains the safe default'
fi

if ((failures > 0)); then
  printf 'PREFLIGHT=failed (%d failure(s))\n' "$failures" >&2
  exit 1
fi

echo 'PREFLIGHT=passed-read-only'
echo 'No storage, container, database, or service state was changed.'
