#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967}"
VLLM_CONTAINER="${VLLM_CONTAINER:-vllm-qwen3-8b}"
VLLM_MODEL_SOURCE="${VLLM_MODEL_SOURCE:-${MODEL_FAST_SOURCE:-nvidia/Qwen3-8B-NVFP4}}"
VLLM_SERVED_MODEL="${VLLM_SERVED_MODEL:-${MODEL_FAST_ALIAS:-exocortex-chat-fast}}"
VLLM_BIND="${VLLM_BIND:-127.0.0.1}"
VLLM_PORT="${VLLM_PORT:-8001}"
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-32768}"
VLLM_GPU_MEMORY_UTILIZATION="${VLLM_GPU_MEMORY_UTILIZATION:-0.25}"

command -v docker >/dev/null
docker info >/dev/null

mkdir -p "$HOME/.cache/huggingface"

if docker container inspect "$VLLM_CONTAINER" >/dev/null 2>&1; then
  echo "Using existing container: $VLLM_CONTAINER"
  docker update --restart unless-stopped "$VLLM_CONTAINER" >/dev/null
  docker start "$VLLM_CONTAINER" >/dev/null
else
  docker run -d \
    --name "$VLLM_CONTAINER" \
    --restart unless-stopped \
    --gpus all \
    --ipc host \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    -p "$VLLM_BIND:$VLLM_PORT:8000" \
    -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
    "$VLLM_IMAGE" \
    "$VLLM_MODEL_SOURCE" \
    --host 0.0.0.0 \
    --port 8000 \
    --served-model-name "$VLLM_SERVED_MODEL" \
    --tensor-parallel-size 1 \
    --trust-remote-code \
    --gpu-memory-utilization "$VLLM_GPU_MEMORY_UTILIZATION" \
    --max-model-len "$VLLM_MAX_MODEL_LEN" \
    --max-num-seqs 8 \
    --max-num-batched-tokens 8192 \
    --enable-chunked-prefill \
    --enable-prefix-caching \
    --reasoning-parser qwen3 \
    --enable-auto-tool-choice \
    --tool-call-parser hermes \
    --default-chat-template-kwargs '{"enable_thinking":false}' >/dev/null
fi

echo "Waiting for $VLLM_MODEL_SOURCE to download and start..."
for _ in $(seq 1 180); do
  if curl -fsS "http://127.0.0.1:$VLLM_PORT/health" >/dev/null 2>&1; then
    echo "vLLM ready: http://127.0.0.1:$VLLM_PORT/v1 model=$VLLM_SERVED_MODEL"
    exit 0
  fi
  if [[ "$(docker inspect "$VLLM_CONTAINER" --format '{{.State.Running}}')" != true ]]; then
    echo 'vLLM container exited. Recent logs:' >&2
    docker logs --tail 100 "$VLLM_CONTAINER" >&2
    exit 1
  fi
  sleep 10
done

echo 'vLLM did not become healthy within 30 minutes. Recent logs:' >&2
docker logs --tail 100 "$VLLM_CONTAINER" >&2
exit 1
