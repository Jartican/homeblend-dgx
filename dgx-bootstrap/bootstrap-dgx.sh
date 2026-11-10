#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"

echo 'Exocortex DGX Spark bootstrap'
echo '==========================='

[[ "$(uname -m)" == aarch64 ]] || { echo 'This bootstrap requires DGX Spark ARM64.' >&2; exit 1; }
free_kib="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
(( free_kib >= 30000000 )) || { echo 'At least 30 GB free disk space is required.' >&2; exit 1; }

for command in curl docker openssl systemctl; do
  command -v "$command" >/dev/null || {
    echo "Missing required command: $command" >&2
    echo 'Run bootstrap-root.sh first.' >&2
    exit 1
  }
done

docker info >/dev/null 2>&1 || {
  echo 'Docker is installed but unavailable to this user.' >&2
  echo 'Log out and back in after bootstrap-root.sh so Docker group membership takes effect.' >&2
  exit 1
}

"$SCRIPT_DIR/setup-postgres-pgvector.sh"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

DEPLOY_EXOCORTEX_GATEWAY="${DEPLOY_EXOCORTEX_GATEWAY:-0}"
REQUIRE_ENCRYPTED_POSTGRES="${REQUIRE_ENCRYPTED_POSTGRES:-1}"
ALLOW_UNENCRYPTED_GATEWAY_TEST="${ALLOW_UNENCRYPTED_GATEWAY_TEST:-0}"

if [[ "$DEPLOY_EXOCORTEX_GATEWAY" == 1 && "$REQUIRE_ENCRYPTED_POSTGRES" == 1 ]]; then
  "$SCRIPT_DIR/check-postgres-encryption.sh"
fi

MODEL_QUALITY="${MODEL_QUALITY:-${MODEL:-qwen3.8:27b}}"
if ! curl -fsS "$OLLAMA_URL/api/tags" | grep -Fq "\"name\":\"$MODEL_QUALITY\""; then
  echo "Pulling Ollama model: $MODEL_QUALITY"
  ollama pull "$MODEL_QUALITY"
fi

"$SCRIPT_DIR/setup-vllm-qwen3-8b.sh"
"$SCRIPT_DIR/deploy-codex-fast-delegate.sh"
"$SCRIPT_DIR/setup-coding-lab.sh"

MODEL="$MODEL_QUALITY" \
CONTEXT_TOKENS="${CONTEXT_TOKENS:-262144}" \
OLLAMA_URL="$OLLAMA_URL" \
LITELLM_HOST="$LITELLM_HOST" \
LITELLM_PORT="$LITELLM_PORT" \
LITELLM_KEY="$LITELLM_KEY" \
VLLM_URL="${VLLM_URL:-http://127.0.0.1:8001/v1}" \
VLLM_SERVED_MODEL="${VLLM_SERVED_MODEL:-${MODEL_FAST_ALIAS:-exocortex-chat-fast}}" \
"$SCRIPT_DIR/setup-claude-qwen.sh"

"$SCRIPT_DIR/setup-tools-mcp.sh"
"$SCRIPT_DIR/setup-open-webui.sh"

if [[ "$DEPLOY_EXOCORTEX_GATEWAY" == 1 ]]; then
  gateway_args=()
  if [[ "$ALLOW_UNENCRYPTED_GATEWAY_TEST" == 1 ]]; then
    gateway_args+=(--allow-unencrypted-test)
  fi
  "$SCRIPT_DIR/deploy-exocortex-gateway.sh" "${gateway_args[@]}"
  if [[ "$ALLOW_UNENCRYPTED_GATEWAY_TEST" != 1 ]]; then
    "$SCRIPT_DIR/apply-private-assistant-schema.sh"
  fi
  if [[ "${DEPLOY_HOME_BLEND_ROUTER:-1}" == 1 ]]; then
    "$SCRIPT_DIR/deploy-home-blend-router.sh"
    "$SCRIPT_DIR/test-home-blend-router.sh"
  fi
  if [[ "${DEPLOY_CLAUDE_SMART_ROUTER:-1}" == 1 ]]; then
    "$SCRIPT_DIR/deploy-claude-smart-router.sh"
    "$SCRIPT_DIR/test-claude-smart-router.sh"
  fi
fi

if [[ "${DEPLOY_PRIVATE_VOICE_STACK:-1}" == 1 ]]; then
  "$SCRIPT_DIR/setup-homeblend-harness.sh"
  "$SCRIPT_DIR/setup-private-voice-stack.sh"
fi

if [[ "${DEPLOY_VLLM_SEMANTIC_ROUTER:-0}" == 1 ]]; then
  "$SCRIPT_DIR/setup-vllm-semantic-router.sh"
  "$SCRIPT_DIR/test-vllm-semantic-router.sh"
fi

echo
echo 'Bootstrap complete.'
echo 'Claude Code: claude-qwen'
echo 'Postgres backup: backup-exocortex-postgres'
echo "Shared MCP tools: http://127.0.0.1:${MCP_GATEWAY_PORT:-8766}/mcp"
if [[ "${DEPLOY_PRIVATE_VOICE_STACK:-1}" == 1 ]]; then
  echo "Private Voice Core: http://127.0.0.1:${VOICE_GATEWAY_PORT:-8791}/health"
fi
echo 'Codex fast-delegate helper: ~/.local/share/exocortex-delegate/delegate_fast_remote.py'
echo 'Synthetic coding benchmark: ~/dgx-bootstrap/run-coding-lab.sh'
echo 'Synthetic local-first canary: ~/dgx-bootstrap/run-coding-canary.sh'
if [[ "${DEPLOY_VLLM_SEMANTIC_ROUTER:-0}" == 1 ]]; then
  echo "vLLM Semantic Router shadow challenger: http://127.0.0.1:${VLLM_SR_PORT:-8899}"
fi
if [[ "$DEPLOY_EXOCORTEX_GATEWAY" == 1 ]]; then
  echo 'Exocortex routing/logging gateway: http://127.0.0.1:4010'
  if [[ "${DEPLOY_HOME_BLEND_ROUTER:-1}" == 1 ]]; then
    echo 'HomeBlend OpenAI-compatible route: exocortex-home-blend (private DGX endpoint)'
  fi
  if [[ "${DEPLOY_CLAUDE_SMART_ROUTER:-1}" == 1 ]]; then
    echo 'Claude smart router (non-persisting): http://127.0.0.1:4011'
  fi
fi
echo
echo 'Privileged one-time steps, if not already completed:'
echo "  sudo loginctl enable-linger $(whoami)"
echo '  sudo tailscale up                         # interactive login, or use an ephemeral auth key'
echo '  sudo tailscale serve --bg 12000          # tailnet-only Open WebUI'
