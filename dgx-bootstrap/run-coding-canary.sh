#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_DIR="${EXOCORTEX_BOOTSTRAP_DIR:-$HOME/dgx-bootstrap}"
LAB_DIR="${EXOCORTEX_CODING_LAB_DIR:-$BOOTSTRAP_DIR/experiments/offload_lab}"
ENV_FILE="${EXOCORTEX_ENV_FILE:-$HOME/.config/exocortex/stack.env}"
FIXTURE="$LAB_DIR/canary/python-parser"
OUTPUT="${EXOCORTEX_CANARY_OUTPUT:-$LAB_DIR/runs/canary-$(date -u +%Y%m%dT%H%M%SZ)}"

[[ -d "$FIXTURE" ]] || { echo "Missing canary fixture: $FIXTURE" >&2; exit 1; }
docker info >/dev/null
worktree="$(mktemp -d)"
trap 'rm -rf -- "$worktree"' EXIT
cp -a -- "$FIXTURE/." "$worktree/"
git -C "$worktree" init --quiet
chmod -R u=rwX,go=rX "$worktree"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
export LITELLM_API_KEY="${LITELLM_KEY:?missing LITELLM_KEY}"
export PYTHONPATH="$LAB_DIR"

python3 -m coding_lab propose \
  --repo "$worktree" \
  --prompt "Fix parse_pair to split only the first equals sign, trim key and value, preserve later equals signs, and raise ValueError for a missing separator or empty key." \
  --allow src/parser.py \
  --test-command "python -m unittest discover -s tests -v" \
  --providers "$LAB_DIR/coding.providers.live.example.json" \
  --provider spark_quality \
  --output "$OUTPUT" \
  --mode local-first \
  --max-turns 8
echo "Synthetic canary evidence: $OUTPUT"
