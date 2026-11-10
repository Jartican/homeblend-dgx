#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
[[ -r "$ENV_FILE" ]] || { echo "missing $ENV_FILE" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

if [[ -z "${HOMEBLEND_REPO_PATH:-}" ]]; then
  [[ "$SCRIPT_DIR" != *$'\n'* ]] || { echo 'Repository path contains a newline.' >&2; exit 1; }
  printf '\nHOMEBLEND_REPO_PATH=%s\n' "$SCRIPT_DIR" >>"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  export HOMEBLEND_REPO_PATH="$SCRIPT_DIR"
fi
[[ -d "$HOMEBLEND_REPO_PATH" ]] || { echo "HOMEBLEND_REPO_PATH is not a directory" >&2; exit 1; }

export LOCAL_UID="$(id -u)"
export LOCAL_GID="$(id -g)"
docker info >/dev/null
docker compose --env-file "$ENV_FILE" --file "$SCRIPT_DIR/compose.harness.yaml" up --detach --build

for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8770/health >/dev/null 2>&1; then
    echo "HomeBlend harness ready: http://127.0.0.1:8770/v1"
    exit 0
  fi
  sleep 2
done

docker logs --tail 100 "${HOMEBLEND_HARNESS_CONTAINER:-homeblend-harness}" >&2 || true
echo "HomeBlend harness did not become healthy" >&2
exit 1
