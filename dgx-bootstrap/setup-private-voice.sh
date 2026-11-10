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
: "${OPEN_WEBUI_CONTAINER:=open-webui}"
: "${SPEACHES_CONTAINER:=exocortex-speaches}"
: "${SPEACHES_STT_MODEL:=Systran/faster-distil-whisper-small.en}"
: "${SPEACHES_WAKE_STT_MODEL:=Systran/faster-whisper-tiny.en}"
: "${SPEACHES_TTS_MODEL:=speaches-ai/Kokoro-82M-v1.0-ONNX}"

docker network inspect "$OPEN_WEBUI_NETWORK" >/dev/null 2>&1 || {
  echo "Missing Docker network $OPEN_WEBUI_NETWORK; run setup-tools-mcp.sh first." >&2
  exit 1
}
docker network inspect "$EXOCORTEX_VOICE_NETWORK" >/dev/null 2>&1 || \
  docker network create --internal "$EXOCORTEX_VOICE_NETWORK" >/dev/null
docker compose --env-file "$ENV_FILE" --file "$SCRIPT_DIR/compose.voice.yaml" up --detach --build speaches

echo 'Waiting for private speech service and initial model downloads...'
for _ in $(seq 1 180); do
  status="$(docker inspect "$SPEACHES_CONTAINER" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  [[ "$status" == healthy ]] && break
  [[ "$status" == exited || "$status" == dead ]] && {
    docker logs --tail 100 "$SPEACHES_CONTAINER" >&2
    exit 1
  }
  sleep 5
done
[[ "$(docker inspect "$SPEACHES_CONTAINER" --format '{{.State.Health.Status}}')" == healthy ]] || {
  docker logs --tail 100 "$SPEACHES_CONTAINER" >&2
  echo 'Speech service did not become healthy.' >&2
  exit 1
}
docker exec "$SPEACHES_CONTAINER" python -c \
  'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8000/health", timeout=5).read()'

# Model downloads temporarily need the egress network. It is disconnected again
# below before normal inference, including when this script is rerun.
if ! docker inspect "$SPEACHES_CONTAINER" --format '{{json .NetworkSettings.Networks}}' | grep -Fq "\"$OPEN_WEBUI_NETWORK\""; then
  docker network connect "$OPEN_WEBUI_NETWORK" "$SPEACHES_CONTAINER"
fi
models_json="$(docker exec "$SPEACHES_CONTAINER" python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8000/v1/models").read().decode())')"
for model in "$SPEACHES_STT_MODEL" "$SPEACHES_WAKE_STT_MODEL" "$SPEACHES_TTS_MODEL"; do
  if ! MODEL_ID="$model" python3 -c 'import json,os,sys; data=json.load(sys.stdin); raise SystemExit(0 if any(x.get("id")==os.environ["MODEL_ID"] for x in data.get("data",[])) else 1)' <<<"$models_json"; then
    echo "Downloading private speech model: $model"
    docker exec -e MODEL_ID="$model" "$SPEACHES_CONTAINER" python -c \
      'import os,urllib.request; urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8000/v1/models/"+os.environ["MODEL_ID"], method="POST"), timeout=1800).read()'
    models_json="$(docker exec "$SPEACHES_CONTAINER" python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8000/v1/models").read().decode())')"
  fi
done

# Model acquisition needs temporary egress. Normal inference does not.
if docker container inspect "$OPEN_WEBUI_CONTAINER" >/dev/null 2>&1; then
  if ! docker inspect "$OPEN_WEBUI_CONTAINER" --format '{{json .NetworkSettings.Networks}}' | grep -Fq "\"$EXOCORTEX_VOICE_NETWORK\""; then
    docker network connect "$EXOCORTEX_VOICE_NETWORK" "$OPEN_WEBUI_CONTAINER"
  fi
fi
if docker inspect "$SPEACHES_CONTAINER" --format '{{json .NetworkSettings.Networks}}' | grep -Fq "\"$OPEN_WEBUI_NETWORK\""; then
  docker network disconnect "$OPEN_WEBUI_NETWORK" "$SPEACHES_CONTAINER"
fi

: "${VOICE_GATEWAY_CONTAINER:=exocortex-voice-gateway}"
: "${VOICE_GATEWAY_PORT:=8791}"
speaches_private_ip="$(docker inspect "$SPEACHES_CONTAINER" \
  --format "{{with index .NetworkSettings.Networks \"$EXOCORTEX_VOICE_NETWORK\"}}{{.IPAddress}}{{end}}")"
[[ -n "$speaches_private_ip" ]] || { echo 'Could not resolve private Speaches container address.' >&2; exit 1; }
export VOICE_SPEACHES_URL="http://$speaches_private_ip:8000/v1"
speaker_container="${SPEAKER_CONTAINER:-exocortex-speaker-verifier}"
if docker container inspect "$speaker_container" >/dev/null 2>&1; then
  speaker_private_ip="$(docker inspect "$speaker_container" \
    --format "{{with index .NetworkSettings.Networks \"$EXOCORTEX_VOICE_NETWORK\"}}{{.IPAddress}}{{end}}")"
  if [[ -n "$speaker_private_ip" ]]; then
    export VOICE_SPEAKER_URL="http://$speaker_private_ip:8000/v1/speaker"
  fi
fi
wake_container="${NEURAL_WAKE_CONTAINER:-exocortex-neural-wake}"
if docker container inspect "$wake_container" >/dev/null 2>&1; then
  wake_private_ip="$(docker inspect "$wake_container" \
    --format "{{with index .NetworkSettings.Networks \"$EXOCORTEX_VOICE_NETWORK\"}}{{.IPAddress}}{{end}}")"
  if [[ -n "$wake_private_ip" ]]; then
    export VOICE_NEURAL_WAKE_URL="http://$wake_private_ip:8000"
  fi
fi
denoiser_container="${DENOISER_CONTAINER:-exocortex-denoiser}"
if docker container inspect "$denoiser_container" >/dev/null 2>&1; then
  denoiser_private_ip="$(docker inspect "$denoiser_container" \
    --format "{{with index .NetworkSettings.Networks \"$EXOCORTEX_VOICE_NETWORK\"}}{{.IPAddress}}{{end}}")"
  if [[ -n "$denoiser_private_ip" ]]; then
    export VOICE_DENOISER_URL="http://$denoiser_private_ip:8000"
  fi
fi
diarization_container="${DIARIZATION_CONTAINER:-exocortex-diarization}"
if docker container inspect "$diarization_container" >/dev/null 2>&1; then
  diarization_private_ip="$(docker inspect "$diarization_container" \
    --format "{{with index .NetworkSettings.Networks \"$EXOCORTEX_VOICE_NETWORK\"}}{{.IPAddress}}{{end}}")"
  if [[ -n "$diarization_private_ip" ]]; then
    export VOICE_DIARIZATION_URL="http://$diarization_private_ip:8000"
  fi
fi
docker compose --env-file "$ENV_FILE" --file "$SCRIPT_DIR/compose.voice.yaml" \
  up --detach --build --no-deps voice-gateway
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$VOICE_GATEWAY_PORT/health" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "http://127.0.0.1:$VOICE_GATEWAY_PORT/health" >/dev/null || {
  docker logs --tail 100 "$VOICE_GATEWAY_CONTAINER" >&2
  echo 'Private voice gateway did not become healthy.' >&2
  exit 1
}

cat <<EOF
Private speech service is healthy.
Open WebUI container endpoint: http://$SPEACHES_CONTAINER:8000/v1
Normal speech inference network: $EXOCORTEX_VOICE_NETWORK (internal-only)
Loopback voice-turn API: http://127.0.0.1:$VOICE_GATEWAY_PORT/v1/voice/turn
Voice Core v2 capabilities: http://127.0.0.1:$VOICE_GATEWAY_PORT/v2/voice/capabilities
Run $SCRIPT_DIR/test-private-voice.sh for a synthesized-speech transcription test.
Run $SCRIPT_DIR/test-realtime-voice-v2.sh for the transport/state foundation checks.
For an existing Open WebUI data volume, configure Admin Panel -> Settings ->
Audio with OpenAI-compatible base URL http://$SPEACHES_CONTAINER:8000/v1.
EOF
if [[ "${VOICE_REALTIME_ENABLED:-false}" =~ ^(1|true|yes|on)$ ]]; then
  echo 'Voice Core v2 streaming-turn beta is enabled; it is not yet the production phone/glasses client.'
else
  echo 'Voice Core v2 realtime transport is disabled by default pending native-client qualification.'
fi
