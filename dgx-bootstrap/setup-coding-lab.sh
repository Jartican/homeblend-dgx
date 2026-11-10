#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${EXOCORTEX_CODING_LAB_SOURCE:-$SCRIPT_DIR/../experiments/offload_lab}"
TARGET_DIR="${EXOCORTEX_CODING_LAB_DIR:-$SCRIPT_DIR/experiments/offload_lab}"

if [[ ! -d "$SOURCE_DIR/coding_lab" ]]; then
  if [[ -d "$TARGET_DIR/coding_lab" && -f "$TARGET_DIR/exocortex-coding-core-v0.1.json" ]]; then
    echo "Coding lab is already deployed at $TARGET_DIR"
    exit 0
  fi
  echo "Missing coding-lab source at $SOURCE_DIR" >&2
  echo "Bootstrap from the complete private repository, not a detached dgx-bootstrap folder." >&2
  exit 1
fi

install -d -m 700 "$TARGET_DIR"
install -d -m 700 "$TARGET_DIR/coding_lab"
cp -a -- "$SOURCE_DIR/coding_lab/." "$TARGET_DIR/coding_lab/"
for suite in "$SOURCE_DIR"/suites/exocortex-coding-core-v*.json; do
  install -m 600 "$suite" "$TARGET_DIR/$(basename "$suite")"
done
install -m 600 "$SOURCE_DIR/config/coding.providers.live.example.json" \
  "$TARGET_DIR/coding.providers.live.example.json"
install -d -m 700 "$TARGET_DIR/canary"
cp -a -- "$SOURCE_DIR/canary/." "$TARGET_DIR/canary/"
install -d -m 700 "$TARGET_DIR/runs"
chmod 700 "$SCRIPT_DIR/run-coding-lab.sh"
chmod 700 "$SCRIPT_DIR/run-coding-canary.sh"

PYTHONPATH="$TARGET_DIR" python3 -m coding_lab validate \
  --suite "$TARGET_DIR/exocortex-coding-core-v0.1.json"
echo "Coding lab deployed at $TARGET_DIR"
