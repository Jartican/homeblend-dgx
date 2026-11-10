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
: "${OPEN_WEBUI_NETWORK:=exocortex-tools}"
: "${EXOCORTEX_VOICE_NETWORK:=exocortex-voice}"
: "${DIARIZATION_CONTAINER:=exocortex-diarization}"

sudo "$SCRIPT_DIR/verify-biometric-vault.sh"
docker network inspect "$OPEN_WEBUI_NETWORK" >/dev/null
docker network inspect "$EXOCORTEX_VOICE_NETWORK" >/dev/null
docker compose --env-file "$ENV_FILE" --file "$SCRIPT_DIR/compose.diarization.yaml" \
  up --detach --build diarization

echo 'Waiting for the CPU-only Sortformer model to download and load...'
for _ in $(seq 1 300); do
  state="$(docker inspect "$DIARIZATION_CONTAINER" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  [[ "$state" == healthy ]] && break
  [[ "$state" == exited || "$state" == dead ]] && { docker logs --tail 180 "$DIARIZATION_CONTAINER" >&2; exit 1; }
  sleep 5
done
[[ "$(docker inspect "$DIARIZATION_CONTAINER" --format '{{.State.Health.Status}}')" == healthy ]] || {
  docker logs --tail 180 "$DIARIZATION_CONTAINER" >&2
  exit 1
}

# Keep internet only for first model acquisition. Inference remains reachable
# solely over the internal voice network after this disconnect.
if docker inspect "$DIARIZATION_CONTAINER" --format '{{json .NetworkSettings.Networks}}' | grep -Fq "\"$OPEN_WEBUI_NETWORK\""; then
  docker network disconnect "$OPEN_WEBUI_NETWORK" "$DIARIZATION_CONTAINER"
fi
echo 'Sortformer diarization is healthy, CPU-only, and internal-network-only.'
if docker container inspect "${VOICE_GATEWAY_CONTAINER:-exocortex-voice-gateway}" >/dev/null 2>&1; then
  "$SCRIPT_DIR/setup-private-voice.sh"
fi
