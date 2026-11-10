#!/usr/bin/env bash
set -Eeuo pipefail

VOICE_URL="${VOICE_URL:-http://127.0.0.1:8791}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT

curl -fsS -X POST \
  -F 'text=Hello Gauss. I am the first speaker. The weather is clear today, and I would like to take a walk outside.' \
  -F 'voice=af_heart' \
  "$VOICE_URL/v1/voice/speech" -o "$WORK_DIR/a.wav"
curl -fsS -X POST \
  -F 'text=Hello there. I am the second speaker. I think we should bring a jacket and return before dinner.' \
  -F 'voice=am_adam' \
  "$VOICE_URL/v1/voice/speech" -o "$WORK_DIR/b.wav"

python3 - "$WORK_DIR/a.wav" "$WORK_DIR/b.wav" "$WORK_DIR/two.wav" <<'PY'
import sys
import wave

with wave.open(sys.argv[1], "rb") as first, wave.open(sys.argv[2], "rb") as second:
    first_format = (first.getnchannels(), first.getsampwidth(), first.getframerate(), first.getcomptype())
    second_format = (second.getnchannels(), second.getsampwidth(), second.getframerate(), second.getcomptype())
    if first_format != second_format:
        raise SystemExit("synthetic voices returned incompatible WAV formats")
    parameters = first.getparams()
    frames = first.readframes(first.getnframes()) + second.readframes(second.getnframes())
with wave.open(sys.argv[3], "wb") as output:
    output.setparams(parameters)
    output.writeframes(frames)
PY

without_consent="$(curl -sS -o "$WORK_DIR/rejected.json" -w '%{http_code}' -X POST \
  -F "audio=@$WORK_DIR/two.wav;type=audio/wav" \
  "$VOICE_URL/v1/voice/diarize")"
[[ "$without_consent" == 403 ]] || {
  echo "Expected HTTP 403 without consent, received $without_consent" >&2
  cat "$WORK_DIR/rejected.json" >&2
  exit 1
}

result="$(curl -fsS -X POST \
  -F "audio=@$WORK_DIR/two.wav;type=audio/wav" \
  -F 'consent=true' \
  "$VOICE_URL/v1/voice/diarize")"
python3 - "$result" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
assert result["raw_audio_persisted"] is False
assert result["consent_recorded_for_request"] is True
assert result["speaker_count"] >= 2, result
assert len(result["segments"]) >= 2, result
print(json.dumps(result, indent=2))
PY

labeled="$(curl -fsS -X POST \
  -F "audio=@$WORK_DIR/two.wav;type=audio/wav" \
  -F 'consent=true' \
  "$VOICE_URL/v1/voice/transcript")"
python3 - "$labeled" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
assert result["raw_audio_persisted"] is False
assert result["derived_transcript_persisted"] is False
assert result["speaker_count"] >= 2, result
assert len(result["segments"]) >= 2, result
assert all(segment.get("text") for segment in result["segments"]), result
print(json.dumps(result, indent=2))
PY
