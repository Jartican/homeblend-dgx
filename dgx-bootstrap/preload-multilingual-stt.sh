#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_ID="${SPEACHES_MULTILINGUAL_STT_MODEL:-Systran/faster-whisper-small}"
SPEACHES_CONTAINER="${SPEACHES_CONTAINER:-exocortex-speaches}"

container_ip="$({
  docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "$SPEACHES_CONTAINER"
} 2>/dev/null)"
[[ "$container_ip" =~ ^[0-9]+([.][0-9]+){3}$ ]] || {
  echo "Could not resolve the private Speaches container address" >&2
  exit 2
}
api="http://${container_ip}:8000/v1"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

# Keep the production speech container on its isolated network. A disposable
# downloader receives temporary egress and writes only into the existing cache.
speaches_image="$(docker inspect --format '{{.Config.Image}}' "$SPEACHES_CONTAINER")"
cache_volume="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/home/ubuntu/.cache/huggingface/hub"}}{{.Name}}{{end}}{{end}}' "$SPEACHES_CONTAINER")"
[[ -n "$speaches_image" && "$cache_volume" =~ ^[A-Za-z0-9_.-]+$ ]] || {
  echo "Could not resolve the Speaches image and cache volume" >&2
  exit 2
}
docker run --rm --network bridge \
  -v "$cache_volume:/home/ubuntu/.cache/huggingface/hub" \
  --entrypoint huggingface-cli \
  "$speaches_image" download "$MODEL_ID" >/dev/null

# Generate a non-sensitive speech fixture through the already-local TTS model.
curl -fsS --max-time 120 \
  -H 'Content-Type: application/json' \
  -d '{"model":"speaches-ai/Kokoro-82M-v1.0-ONNX","voice":"af_heart","input":"hello","response_format":"wav"}' \
  "$api/audio/speech" -o "$work_dir/hello.wav"

# Speaches resolves and caches the requested ASR model on its first use.
curl -fsS --max-time 1800 \
  -F "file=@$work_dir/hello.wav;type=audio/wav" \
  -F "model=$MODEL_ID" \
  "$api/audio/transcriptions" >/dev/null

curl -fsS --max-time 30 "$api/models" \
  | jq -e --arg model "$MODEL_ID" '.data | any(.id == $model and .task == "automatic-speech-recognition")' \
  >/dev/null

echo "MULTILINGUAL_STT_READY=$MODEL_ID"
echo 'Synthetic fixture removed; no user audio was used.'
