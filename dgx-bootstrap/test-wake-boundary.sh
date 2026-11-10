#!/usr/bin/env bash
set -Eeuo pipefail

VOICE_URL="${VOICE_URL:-http://127.0.0.1:8791}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

curl -fsS -X POST \
  -F 'text=Hey Gauss, can you hear me?' -F 'voice=am_michael' \
  "$VOICE_URL/v1/voice/speech" -o "$WORK_DIR/full.wav"

python3 - "$WORK_DIR/full.wav" "$WORK_DIR/first.wav" "$WORK_DIR/second.wav" <<'PY'
import sys
import wave

with wave.open(sys.argv[1], "rb") as source:
    parameters = source.getparams()
    split_frame = min(int(source.getframerate() * 0.55), source.getnframes() - 1)
    first = source.readframes(split_frame)
    second = source.readframes(source.getnframes() - split_frame)
for path, frames in ((sys.argv[2], first), (sys.argv[3], second)):
    with wave.open(path, "wb") as output:
        output.setparams(parameters)
        output.writeframes(frames)
PY

first="$(curl -fsS -X POST \
  -F "audio=@$WORK_DIR/first.wav;type=audio/wav" \
  -F 'session_id=boundary-regression' "$VOICE_URL/v1/voice/wake")"
second="$(curl -fsS -X POST \
  -F "audio=@$WORK_DIR/second.wav;type=audio/wav" \
  -F 'session_id=boundary-regression' "$VOICE_URL/v1/voice/wake")"
python3 - "$first" "$second" <<'PY'
import json
import sys

first, second = map(json.loads, sys.argv[1:])
assert first["heard"] or second["heard"], {"first": first, "second": second}
print(json.dumps({"first_clip": first, "second_clip": second}, indent=2))
PY
