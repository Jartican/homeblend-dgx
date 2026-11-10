#!/usr/bin/env bash
set -euo pipefail

# Runs the synthetic coding-agent benchmark on the DGX. The model endpoint and
# Docker sandbox remain loopback/local; no private repository is copied here.
BOOTSTRAP_DIR="${EXOCORTEX_BOOTSTRAP_DIR:-$HOME/dgx-bootstrap}"
LAB_DIR="${EXOCORTEX_CODING_LAB_DIR:-$BOOTSTRAP_DIR/experiments/offload_lab}"
ENV_FILE="${EXOCORTEX_ENV_FILE:-$HOME/.config/exocortex/stack.env}"
PROVIDER="${EXOCORTEX_CODING_PROVIDER:-spark_quality}"
OUTPUT="${EXOCORTEX_CODING_OUTPUT:-$LAB_DIR/runs/coding-$(date -u +%Y%m%dT%H%M%SZ)}"
SUITE="${EXOCORTEX_CODING_SUITE:-exocortex-coding-core-v0.1.json}"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "Missing Exocortex environment file: $ENV_FILE" >&2
  exit 1
fi
if [[ ! -f "$LAB_DIR/$SUITE" ]]; then
  echo "Coding suite is not deployed under $LAB_DIR" >&2
  exit 1
fi
docker info >/dev/null
curl --fail --silent --show-error http://127.0.0.1:4000/health/liveliness >/dev/null

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
export LITELLM_API_KEY="${LITELLM_KEY:?LITELLM_KEY is missing from $ENV_FILE}"
export PYTHONPATH="$LAB_DIR"

arguments=(
  -m coding_lab run
  --suite "$LAB_DIR/$SUITE"
  --providers "$LAB_DIR/coding.providers.live.example.json"
  --provider "$PROVIDER"
  --output "$OUTPUT"
)
if [[ $# -eq 0 ]]; then
  arguments+=(--task boundary_fix-01)
else
  arguments+=("$@")
fi
python3 "${arguments[@]}"
