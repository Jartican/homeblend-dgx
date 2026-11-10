#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_SETUP="$SCRIPT_DIR/../dgx-bootstrap/setup-claude-qwen.sh"

[[ -x "$CANONICAL_SETUP" ]] || {
  echo "Canonical installer not found: $CANONICAL_SETUP" >&2
  echo 'Run the complete dgx-bootstrap bundle on a new DGX Spark.' >&2
  exit 1
}

exec "$CANONICAL_SETUP" "$@"
