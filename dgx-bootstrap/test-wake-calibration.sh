#!/usr/bin/env bash
set -Eeuo pipefail

VOICE_URL="${VOICE_URL:-http://127.0.0.1:8791}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT
voices=(af_heart am_michael bm_george)
negatives=(
  'The glass is full of gas because it is cold.'
  'We discussed cause and effect.'
  'Please go outside now.'
)
index=0

check_phrase() {
  local voice="$1" phrase="$2" expected="$3" response
  index=$((index + 1))
  curl -fsS -X POST -F "text=$phrase" -F "voice=$voice" \
    "$VOICE_URL/v1/voice/speech" -o "$WORK_DIR/$index.wav"
  response="$(curl -fsS -X POST \
    -F "audio=@$WORK_DIR/$index.wav;type=audio/wav" \
    -F "session_id=calibration-$index" \
    "$VOICE_URL/v1/voice/wake")"
  python3 - "$voice" "$phrase" "$expected" "$response" <<'PY'
import json
import sys

voice, phrase, expected, raw = sys.argv[1:]
result = json.loads(raw)
actual = bool(result["heard"])
print(f"{voice}: {phrase!r} -> heard={actual}")
assert actual is (expected == "true"), result
PY
  sleep 1
}

for voice in "${voices[@]}"; do
  check_phrase "$voice" 'Hey Gauss, can you hear me?' true
  for phrase in "${negatives[@]}"; do
    check_phrase "$voice" "$phrase" false
  done
done
echo 'Wake calibration matrix: pass (3 positives, 9 confusable negatives).'
