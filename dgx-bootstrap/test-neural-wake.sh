#!/usr/bin/env bash
set -Eeuo pipefail

VOICE_URL="${VOICE_URL:-http://127.0.0.1:8791}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

curl -fsS -X POST -F 'text=Gauss' -F 'voice=af_heart' \
  "$VOICE_URL/v1/voice/speech" -o "$WORK_DIR/gauss.wav"
curl -fsS -X POST -F 'text=The weather is clear outside.' -F 'voice=af_heart' \
  "$VOICE_URL/v1/voice/speech" -o "$WORK_DIR/negative.wav"
python3 - "$WORK_DIR/gauss.wav" "$WORK_DIR/silence.wav" <<'PY'
import sys
import wave

with wave.open(sys.argv[1], "rb") as source:
    parameters = source.getparams()
    silence = b"\0" * parameters.framerate * parameters.nchannels * parameters.sampwidth
with wave.open(sys.argv[2], "wb") as output:
    output.setparams(parameters)
    output.writeframes(silence)
PY

positive="$(curl -fsS -X POST \
  -F "audio=@$WORK_DIR/gauss.wav;type=audio/wav" \
  -F 'session_id=synthetic-positive' \
  "$VOICE_URL/v1/voice/wake")"
positive_tail="$(curl -fsS -X POST \
  -F "audio=@$WORK_DIR/silence.wav;type=audio/wav" \
  -F 'session_id=synthetic-positive' \
  "$VOICE_URL/v1/voice/wake")"
negative="$(curl -fsS -X POST \
  -F "audio=@$WORK_DIR/negative.wav;type=audio/wav" \
  -F 'session_id=synthetic-negative' \
  "$VOICE_URL/v1/voice/wake")"
negative_tail="$(curl -fsS -X POST \
  -F "audio=@$WORK_DIR/silence.wav;type=audio/wav" \
  -F 'session_id=synthetic-negative' \
  "$VOICE_URL/v1/voice/wake")"

python3 - "$positive" "$positive_tail" "$negative" "$negative_tail" <<'PY'
import json
import sys

positive, positive_tail, negative, negative_tail = map(json.loads, sys.argv[1:])
assert positive["heard"] or positive_tail["heard"], {"voice": positive, "tail": positive_tail}
assert positive["engine"] == "sherpa-onnx-zipformer-kws", positive
assert positive["raw_audio_persisted"] is False, positive
assert not negative["heard"] and not negative_tail["heard"], {"voice": negative, "tail": negative_tail}
assert negative["raw_audio_persisted"] is False, negative
print(json.dumps({
    "positive_voice": positive,
    "positive_natural_silence": positive_tail,
    "negative_voice": negative,
    "negative_natural_silence": negative_tail,
}, indent=2))
PY
