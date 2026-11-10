#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_COMMIT="${VLLM_SR_SOURCE_COMMIT:-6aed6c1a5511fa825df229633b80ff5b49e8ffb7}"
WORK_ROOT="${VLLM_SR_TRAIN_ROOT:-$HOME/.local/share/exocortex-vllm-sr-training}"
LAB_ROOT="${EXOCORTEX_OFFLOAD_LAB_ROOT:-$HOME/exocortex-offload-lab}"
DEFAULT_DATA_FILE="$LAB_ROOT/artifacts/router-v0.6/training.jsonl"
if [[ ! -f "$DEFAULT_DATA_FILE" && -f "$HOME/dgx-bootstrap/experiments/offload_lab/artifacts/router-v0.6/training.jsonl" ]]; then
  DEFAULT_DATA_FILE="$HOME/dgx-bootstrap/experiments/offload_lab/artifacts/router-v0.6/training.jsonl"
fi
DATA_FILE="${1:-$DEFAULT_DATA_FILE}"
OUTPUT_DIR="${2:-$WORK_ROOT/artifacts}"
REPO_DIR="$WORK_ROOT/source"
VENV_DIR="$WORK_ROOT/venv"

[[ -f "$DATA_FILE" ]] || { echo "Training data not found: $DATA_FILE" >&2; exit 1; }
for command in git python3; do command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }; done
install -d -m 700 "$WORK_ROOT" "$OUTPUT_DIR"
export HF_HOME="$WORK_ROOT/huggingface"
export XDG_CACHE_HOME="$WORK_ROOT/cache-home"
install -d -m 700 "$HF_HOME" "$XDG_CACHE_HOME"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  git clone --filter=blob:none https://github.com/vllm-project/semantic-router.git "$REPO_DIR"
fi
git -C "$REPO_DIR" fetch --depth 1 origin "$SOURCE_COMMIT"
git -C "$REPO_DIR" checkout --detach "$SOURCE_COMMIT"

python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip
trainer="$REPO_DIR/src/training/model_selection/ml_model_selection"
"$VENV_DIR/bin/python" -m pip install -r "$trainer/requirements.txt"

for algorithm in knn svm; do
  "$VENV_DIR/bin/python" "$trainer/train.py" \
    --data-file "$DATA_FILE" \
    --output-dir "$OUTPUT_DIR" \
    --cache-dir "$WORK_ROOT/cache" \
    --embedding-model qwen3 \
    --algorithm "$algorithm" \
    --device cpu
done

sha256sum "$DATA_FILE" "$OUTPUT_DIR/knn_model.json" "$OUTPUT_DIR/svm_model.json" > "$OUTPUT_DIR/SHA256SUMS"
{
  printf 'source_commit=%s\n' "$SOURCE_COMMIT"
  printf 'embedding_model=%s\n' 'Qwen/Qwen3-Embedding-0.6B'
  printf 'embedding_dimension=1024\n'
  printf 'runtime_compatibility=requires_model_selection.model_type_qwen3_and_embedding_dim_1024\n'
  printf 'unique_queries=%s\n' "$(python3 -c 'import json,sys; print(len({json.loads(x)["query"] for x in open(sys.argv[1], encoding="utf-8") if x.strip()}))' "$DATA_FILE")"
  printf 'algorithms=knn,svm\n'
  printf 'promotion_eligible=false\n'
  printf 'reason=v0.5_reuse_and_failed_judge_calibration\n'
} > "$OUTPUT_DIR/TRAINING-MANIFEST.txt"
chmod 600 "$OUTPUT_DIR"/*
echo "Diagnostic artifacts written to $OUTPUT_DIR"
