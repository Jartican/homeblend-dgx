#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${OPEN_WEBUI_CONTAINER:=open-webui}"
: "${SPEACHES_CONTAINER:=exocortex-speaches}"
: "${SPEACHES_STT_MODEL:=Systran/faster-distil-whisper-small.en}"
: "${SPEACHES_TTS_MODEL:=speaches-ai/Kokoro-82M-v1.0-ONNX}"
: "${SPEACHES_TTS_VOICE:=af_heart}"

docker container inspect "$OPEN_WEBUI_CONTAINER" >/dev/null
docker exec \
  -e SPEACHES_URL="http://$SPEACHES_CONTAINER:8000/v1" \
  -e SPEACHES_STT_MODEL="$SPEACHES_STT_MODEL" \
  -e SPEACHES_TTS_MODEL="$SPEACHES_TTS_MODEL" \
  -e SPEACHES_TTS_VOICE="$SPEACHES_TTS_VOICE" \
  "$OPEN_WEBUI_CONTAINER" python -c '
import os, requests
base = os.environ["SPEACHES_URL"]
speech = requests.post(base + "/audio/speech", json={
    "model": os.environ["SPEACHES_TTS_MODEL"],
    "voice": os.environ["SPEACHES_TTS_VOICE"],
    "input": "HomeBlend private voice is working.",
    "response_format": "wav",
}, timeout=180)
speech.raise_for_status()
result = requests.post(
    base + "/audio/transcriptions",
    files={"file": ("private-voice.wav", speech.content, "audio/wav")},
    data={"model": os.environ["SPEACHES_STT_MODEL"]},
    timeout=180,
)
result.raise_for_status()
text = result.json().get("text", "")
print("Transcript:", text)
if "private voice" not in text.lower():
    raise SystemExit("round-trip transcript did not contain the expected phrase")
'
echo 'Private TTS -> STT round-trip passed.'
