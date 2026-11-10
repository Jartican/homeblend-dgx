#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VOICE_DIR="${SCRIPT_DIR}/voice-gateway"

python3 -m unittest discover \
  -s "${VOICE_DIR}/tests" \
  -p 'test_*.py'

python3 -m py_compile \
  "${VOICE_DIR}/core.py" \
  "${VOICE_DIR}/realtime_adapters.py" \
  "${VOICE_DIR}/realtime_core.py" \
  "${VOICE_DIR}/realtime_pipeline.py" \
  "${VOICE_DIR}/realtime_protocol.py" \
  "${VOICE_DIR}/realtime_runtime.py" \
  "${VOICE_DIR}/realtime_simulator.py" \
  "${VOICE_DIR}/server.py"

echo "Voice Core v2 foundation checks passed."
