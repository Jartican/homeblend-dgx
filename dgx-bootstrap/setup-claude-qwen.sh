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

MODEL="${MODEL:-${MODEL_QUALITY:-qwen3.8:27b}}"
MODEL_FAST_ALIAS="${MODEL_FAST_ALIAS:-exocortex-chat-fast}"
MODEL_QUALITY_ALIAS="${MODEL_QUALITY_ALIAS:-exocortex-agent-quality}"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
LITELLM_HOST="${LITELLM_HOST:-127.0.0.1}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_KEY="${LITELLM_KEY:-}"
LITELLM_VERSION="${LITELLM_VERSION:-1.98.0}"
CONTEXT_TOKENS="${CONTEXT_TOKENS:-262144}"
VLLM_URL="${VLLM_URL:-http://127.0.0.1:8001/v1}"
VLLM_SERVED_MODEL="${VLLM_SERVED_MODEL:-$MODEL_FAST_ALIAS}"

: "${LITELLM_KEY:?LITELLM_KEY is required; run setup-postgres-pgvector.sh first}"

LOCAL_BIN="$HOME/.local/bin"
LITELLM_DIR="$HOME/.config/litellm"
USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
LITELLM_CONFIG="$LITELLM_DIR/qwen.yaml"
SERVICE_FILE="$USER_SYSTEMD_DIR/litellm-qwen.service"
LAUNCHER="$LOCAL_BIN/claude-qwen"

export PATH="$LOCAL_BIN:$PATH"

need_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

need_command curl
need_command systemctl

mkdir -p "$LOCAL_BIN" "$LITELLM_DIR" "$USER_SYSTEMD_DIR"

if [[ ! -x "$LOCAL_BIN/claude" ]]; then
  echo "Installing Claude Code..."
  curl -fsSL https://claude.ai/install.sh | bash
else
  echo "Claude Code already installed: $($LOCAL_BIN/claude --version)"
fi

if [[ ! -x "$LOCAL_BIN/uv" ]]; then
  echo "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
else
  echo "uv already installed: $($LOCAL_BIN/uv --version)"
fi

echo "Installing LiteLLM $LITELLM_VERSION..."
"$LOCAL_BIN/uv" tool install --force "litellm[proxy]==$LITELLM_VERSION"

"$LOCAL_BIN/uv" tool update-shell || true

echo "Checking Ollama model $MODEL..."
if ! curl -fsS "$OLLAMA_URL/api/tags" | grep -Fq "\"name\":\"$MODEL\""; then
  echo "Ollama is reachable, but $MODEL was not found." >&2
  echo "Install it first with: ollama pull $MODEL" >&2
  exit 1
fi

cat >"$LITELLM_CONFIG" <<EOF
model_list:
  - model_name: $MODEL_FAST_ALIAS
    litellm_params:
      model: openai/$VLLM_SERVED_MODEL
      api_base: $VLLM_URL
      api_key: local-vllm
  - model_name: $MODEL_QUALITY_ALIAS
    litellm_params:
      model: ollama_chat/$MODEL
      api_base: $OLLAMA_URL

general_settings:
  master_key: $LITELLM_KEY

litellm_settings:
  drop_params: true
EOF
chmod 600 "$LITELLM_CONFIG"

cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Exocortex LiteLLM model gateway
After=network-online.target

[Service]
Type=simple
ExecStart=$LOCAL_BIN/litellm --config $LITELLM_CONFIG --host $LITELLM_HOST --port $LITELLM_PORT
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
chmod 644 "$SERVICE_FILE"

cat >"$LAUNCHER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export ANTHROPIC_BASE_URL="http://$LITELLM_HOST:$LITELLM_PORT"
export ANTHROPIC_AUTH_TOKEN="$LITELLM_KEY"
export ANTHROPIC_API_KEY=""
export ANTHROPIC_MODEL="$MODEL_QUALITY_ALIAS"
export ANTHROPIC_SMALL_FAST_MODEL="$MODEL_QUALITY_ALIAS"
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CONTEXT_TOKENS"
exec "\$HOME/.local/bin/claude" --model "$MODEL_QUALITY_ALIAS" "\$@"
EOF
chmod 700 "$LAUNCHER"

systemctl --user daemon-reload
systemctl --user enable litellm-qwen.service
systemctl --user restart litellm-qwen.service

echo "Waiting for LiteLLM..."
for _ in $(seq 1 30); do
  if curl -fsS -H "Authorization: Bearer $LITELLM_KEY" \
      "http://$LITELLM_HOST:$LITELLM_PORT/v1/models" >/dev/null; then
    break
  fi
  sleep 1
done

curl -fsS -H "Authorization: Bearer $LITELLM_KEY" \
  "http://$LITELLM_HOST:$LITELLM_PORT/v1/models" >/dev/null

echo
echo "Setup complete."
echo "Run Claude Code with: $LAUNCHER"
echo "Gateway: http://$LITELLM_HOST:$LITELLM_PORT"
echo "Model route: $MODEL_QUALITY_ALIAS ($MODEL)"
echo
echo "Optional: keep the user service running without an active login session:"
echo "  sudo loginctl enable-linger $(whoami)"
