#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
[[ -r "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${VOICE_GATEWAY_PORT:=8791}"
BASE_URL="http://127.0.0.1:$VOICE_GATEWAY_PORT"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

curl -fsS "$BASE_URL/health" >"$TEST_DIR/health.json"
curl -fsS "$BASE_URL/v1/voice/config" >"$TEST_DIR/client-config.json"
CONFIG_FILE="$TEST_DIR/client-config.json" python3 - <<'PY'
import json, os
from pathlib import Path

config = json.loads(Path(os.environ["CONFIG_FILE"]).read_text())
assert config["wake_word"].strip(), config
assert config["wake_aliases"], config
assert 1000 <= config["wake_clip_ms"] <= 10_000, config
assert 3000 <= config["conversation_reply_window_ms"] <= 30_000, config
assert 4000 <= config["stream_start_timeout_ms"] <= 60_000, config
print("Foreground wake-word client configuration:", config)
PY

SILENCE_FILE="$TEST_DIR/silence.wav" python3 - <<'PY'
import os, wave
from pathlib import Path

path = Path(os.environ["SILENCE_FILE"])
with wave.open(str(path), "wb") as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(16_000)
    wav.writeframes(b"\0\0" * 32_000)
PY
curl -fsS -X POST "$BASE_URL/v1/voice/transcribe" \
  -F "audio=@$TEST_DIR/silence.wav;type=audio/wav" \
  -F 'allow_empty=true' -F 'wake_detection=true' >"$TEST_DIR/silence.json"
SILENCE_RESULT="$TEST_DIR/silence.json" python3 - <<'PY'
import json, os
from pathlib import Path

result = json.loads(Path(os.environ["SILENCE_RESULT"]).read_text())
assert result["transcript"] == "", result
assert result["speech_detected"] is False, result
assert result["wake_detection"] is True, result
print("Silent wake clip accepted as a normal no-op")
PY

curl -fsS -X POST "$BASE_URL/v1/voice/speech" \
  -F 'text=Gauss' >"$TEST_DIR/wake-word.wav"
curl -fsS -X POST "$BASE_URL/v1/voice/transcribe" \
  -F "audio=@$TEST_DIR/wake-word.wav;type=audio/wav" \
  -F 'allow_empty=true' -F 'wake_detection=true' >"$TEST_DIR/wake-word.json"
WAKE_RESULT="$TEST_DIR/wake-word.json" CONFIG_FILE="$TEST_DIR/client-config.json" python3 - <<'PY'
import json, os, re
from pathlib import Path

result = json.loads(Path(os.environ["WAKE_RESULT"]).read_text())
config = json.loads(Path(os.environ["CONFIG_FILE"]).read_text())
heard = result["transcript"].lower()
assert any(re.search(rf"\b{re.escape(alias.lower())}\b", heard) for alias in config["wake_aliases"]), result
print("Biased wake-word transcription:", result["transcript"], result["timing_ms"])
PY

curl -fsS -X POST "$BASE_URL/v1/voice/speech-jobs" \
  -F 'text=Gauss private streaming speech is working. The second phrase should arrive while the first phrase plays. The conversation microphone opens after playback.' | \
  tee "$TEST_DIR/speech-job.json" >/dev/null
speech_job="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["job_id"])' "$TEST_DIR/speech-job.json")"
curl -fsS -D "$TEST_DIR/stream-headers.txt" -o "$TEST_DIR/stream.mp3" \
  -w '%{time_starttransfer} %{time_total}' \
  "$BASE_URL/v1/voice/speech-stream/$speech_job" >"$TEST_DIR/stream-timing.txt"
replay_status="$(curl -sS -o /dev/null -w '%{http_code}' \
  "$BASE_URL/v1/voice/speech-stream/$speech_job")"
STREAM_FILE="$TEST_DIR/stream.mp3" TIMING_FILE="$TEST_DIR/stream-timing.txt" HEADERS_FILE="$TEST_DIR/stream-headers.txt" JOB_FILE="$TEST_DIR/speech-job.json" \
REPLAY_STATUS="$replay_status" python3 - <<'PY'
import json, os
from pathlib import Path

stream_file = Path(os.environ["STREAM_FILE"])
first_byte, total = map(float, Path(os.environ["TIMING_FILE"]).read_text().split())
headers = Path(os.environ["HEADERS_FILE"]).read_text().lower()
job = json.loads(Path(os.environ["JOB_FILE"]).read_text())
assert stream_file.stat().st_size > 1000
assert first_byte <= total
assert len(job["job_ids"]) == job["speech_chunks"] == 3, job
assert "x-exocortex-speech-chunks: 1" in headers, headers
assert os.environ["REPLAY_STATUS"] == "404"
print(f"Single-use streaming TTS: first byte {first_byte:.3f}s, total {total:.3f}s")
PY
python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["job_ids"][1:]))' "$TEST_DIR/speech-job.json" | \
while IFS= read -r queued_job; do
  curl -fsS "$BASE_URL/v1/voice/speech-stream/$queued_job" | test "$(wc -c)" -gt 1000
done

# Exercise the staged phone flow independently so the UI can expose genuine
# transcription, inference, and speech progress rather than one opaque wait.
curl -fsS -X POST "$BASE_URL/v1/voice/speech" \
  -F 'text=Staged private voice is working.' >"$TEST_DIR/staged.wav"
curl -fsS -X POST "$BASE_URL/v1/voice/transcribe" \
  -F "audio=@$TEST_DIR/staged.wav;type=audio/wav" >"$TEST_DIR/staged-stt.json"
curl -fsS -X POST "$BASE_URL/v1/voice/transcribe" \
  -F "audio=@$TEST_DIR/staged.wav;type=audio/wav" \
  -F 'allow_empty=true' -F 'command_tail=true' >"$TEST_DIR/command-tail-stt.json"
curl -fsS -X POST "$BASE_URL/v1/voice/respond" \
  -F 'text=Reply with exactly: staged response works' \
  -F 'model=8b' -F 'effort=1' -F 'tool_profile=none' >"$TEST_DIR/staged-response.json"

STT_FILE="$TEST_DIR/staged-stt.json" COMMAND_TAIL_FILE="$TEST_DIR/command-tail-stt.json" RESPONSE_FILE="$TEST_DIR/staged-response.json" \
EXPECTED_MODEL="${MODEL_FAST_ALIAS:-exocortex-chat-fast}" python3 - <<'PY'
import json, os
from pathlib import Path

stt = json.loads(Path(os.environ["STT_FILE"]).read_text())
command_tail = json.loads(Path(os.environ["COMMAND_TAIL_FILE"]).read_text())
response = json.loads(Path(os.environ["RESPONSE_FILE"]).read_text())
assert "staged private voice" in stt["transcript"].lower(), stt
assert command_tail["wake_detection"] is False, command_tail
assert "staged private voice" in command_tail["transcript"].lower(), command_tail
assert response["selected_model"] == os.environ["EXPECTED_MODEL"], response
assert "staged response works" in response["answer"].lower(), response
print("Staged speech -> STT and 8B response:", stt["timing_ms"], response["timing_ms"])
PY

curl -fsS -X POST "$BASE_URL/v1/voice/turn" \
  -F 'text=Reply briefly: private voice through the eight billion parameter model is working.' \
  -F 'model=8b' -F 'effort=1' -F 'tool_profile=none' >"$TEST_DIR/8b.json"

RESPONSE_FILE="$TEST_DIR/8b.json" AUDIO_FILE="$TEST_DIR/8b.wav" \
EXPECTED_MODEL="${MODEL_FAST_ALIAS:-exocortex-chat-fast}" python3 - <<'PY'
import base64, json, os
from pathlib import Path

result = json.loads(Path(os.environ["RESPONSE_FILE"]).read_text())
assert result["selected_model"] == os.environ["EXPECTED_MODEL"], result
assert result["answer"].strip()
assert result["security"]["voice_auth"] == {
    "enabled": False, "status": "not_evaluated", "trusted": False,
}
Path(os.environ["AUDIO_FILE"]).write_bytes(base64.b64decode(result["audio"], validate=True))
assert Path(os.environ["AUDIO_FILE"]).stat().st_size > 44
print("8B text -> inference -> TTS:", result["timing_ms"], result["answer"])
PY

curl -fsS -X POST "$BASE_URL/v1/voice/turn" \
  -F "audio=@$TEST_DIR/8b.wav;type=audio/wav" \
  -F 'model=8b' -F 'effort=1' -F 'tool_profile=none' >"$TEST_DIR/audio.json"

RESPONSE_FILE="$TEST_DIR/audio.json" EXPECTED_MODEL="${MODEL_FAST_ALIAS:-exocortex-chat-fast}" python3 - <<'PY'
import json, os
from pathlib import Path

result = json.loads(Path(os.environ["RESPONSE_FILE"]).read_text())
assert result["selected_model"] == os.environ["EXPECTED_MODEL"], result
assert result["transcript"].strip() and result["answer"].strip()
print("Audio -> STT -> 8B -> TTS:", result["timing_ms"], "transcript:", result["transcript"])
PY

curl -fsS -X POST "$BASE_URL/v1/voice/turn" \
  -F 'text=What word did I ask you to remember? Reply with only that word.' \
  -F 'history_json=[{"role":"user","content":"Remember the word sapphire."},{"role":"assistant","content":"I will remember sapphire."}]' \
  -F 'model=8b' -F 'effort=1' -F 'tool_profile=none' >"$TEST_DIR/history.json"

RESPONSE_FILE="$TEST_DIR/history.json" python3 - <<'PY'
import json, os
from pathlib import Path

result = json.loads(Path(os.environ["RESPONSE_FILE"]).read_text())
assert "sapphire" in result["answer"].lower(), result
print("Client-held conversation history:", result["timing_ms"], result["answer"])
PY

curl -fsS -X POST "$BASE_URL/v1/voice/turn" \
  -F 'text=In one short sentence, confirm that the quality model completed a private voice turn.' \
  -F 'model=27b' -F 'effort=1' -F 'tool_profile=none' >"$TEST_DIR/27b.json"

RESPONSE_FILE="$TEST_DIR/27b.json" EXPECTED_MODEL="${MODEL_QUALITY_ALIAS:-exocortex-agent-quality}" python3 - <<'PY'
import base64, json, os
from pathlib import Path

result = json.loads(Path(os.environ["RESPONSE_FILE"]).read_text())
assert result["selected_model"] == os.environ["EXPECTED_MODEL"], result
assert result["answer"].strip()
assert len(base64.b64decode(result["audio"], validate=True)) > 44
print("27B text -> inference -> TTS:", result["timing_ms"], result["answer"])
PY

if [[ "${VOICE_TEST_WEB:-0}" == 1 ]]; then
  curl -fsS -X POST "$BASE_URL/v1/voice/turn" \
    -F 'text=Use web search to find the official Tailscale Serve documentation and reply with one source URL.' \
    -F 'model=8b' -F 'effort=1' -F 'tool_profile=web' >"$TEST_DIR/web.json"
  RESPONSE_FILE="$TEST_DIR/web.json" python3 - <<'PY'
import json, os
from pathlib import Path

result = json.loads(Path(os.environ["RESPONSE_FILE"]).read_text())
assert "web_search" in result["tool_names"], result
assert "http" in result["answer"].lower(), result
print("8B -> SearXNG -> TTS:", result["timing_ms"], result["answer"])
PY
fi

echo 'Private voice gateway end-to-end tests passed.'
