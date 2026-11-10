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
: "${NEURAL_WAKE_CONTAINER:=exocortex-neural-wake}"
docker network inspect "$EXOCORTEX_VOICE_NETWORK" >/dev/null 2>&1 || \
  docker network create --internal "$EXOCORTEX_VOICE_NETWORK" >/dev/null
docker compose --env-file "$ENV_FILE" --file "$SCRIPT_DIR/compose.wake.yaml" \
  up --detach --build neural-wake
for _ in $(seq 1 60); do
  state="$(docker inspect "$NEURAL_WAKE_CONTAINER" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  [[ "$state" == healthy ]] && break
  [[ "$state" == exited || "$state" == dead ]] && { docker logs --tail 100 "$NEURAL_WAKE_CONTAINER" >&2; exit 1; }
  sleep 2
done
[[ "$(docker inspect "$NEURAL_WAKE_CONTAINER" --format '{{.State.Health.Status}}')" == healthy ]] || {
  docker logs --tail 100 "$NEURAL_WAKE_CONTAINER" >&2
  exit 1
}
echo 'Dedicated sherpa-onnx neural wake service is healthy on the internal voice network.'
