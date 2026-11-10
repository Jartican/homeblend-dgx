#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
: "${EXOCORTEX_VOICE_NETWORK:=exocortex-voice}"
: "${DENOISER_CONTAINER:=exocortex-denoiser}"

docker network inspect "$EXOCORTEX_VOICE_NETWORK" >/dev/null 2>&1 || \
  docker network create --internal "$EXOCORTEX_VOICE_NETWORK" >/dev/null
docker compose --env-file "$ENV_FILE" --file "$SCRIPT_DIR/compose.denoise.yaml" \
  up --detach --build denoiser
for _ in $(seq 1 90); do
  state="$(docker inspect "$DENOISER_CONTAINER" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  [[ "$state" == healthy ]] && break
  [[ "$state" == exited || "$state" == dead ]] && { docker logs --tail 100 "$DENOISER_CONTAINER" >&2; exit 1; }
  sleep 2
done
[[ "$(docker inspect "$DENOISER_CONTAINER" --format '{{.State.Health.Status}}')" == healthy ]] || {
  docker logs --tail 100 "$DENOISER_CONTAINER" >&2
  exit 1
}
echo 'DeepFilterNet3 denoiser is healthy on the internal voice network.'
