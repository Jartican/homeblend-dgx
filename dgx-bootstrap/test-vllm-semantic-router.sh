#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

bind="${VLLM_SR_BIND:-127.0.0.1}"
port="${VLLM_SR_PORT:-8899}"
container="${VLLM_SR_CONTAINER:-exocortex-vllm-sr-v06}"
envoy_container="${VLLM_SR_ENVOY_CONTAINER:-exocortex-vllm-sr-v06-envoy}"

[[ "$bind" == 127.0.0.1 ]] || { echo 'Expected loopback-only bind.' >&2; exit 1; }
docker inspect "$container" "$envoy_container" --format '{{json .HostConfig.PortBindings}}' | grep -Fq '127.0.0.1' || {
  echo 'Challenger is not bound to loopback.' >&2; exit 1;
}

for _ in $(seq 1 90); do
  if curl -fsS "http://$bind:${VLLM_SR_MANAGEMENT_PORT:-18080}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS "http://$bind:${VLLM_SR_MANAGEMENT_PORT:-18080}/health" >/dev/null
curl -fsS "http://$bind:$port/v1/models" >/dev/null

response="$(curl -fsS --max-time 120 "http://$bind:$port/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"Reply with exactly: VSR_OK"}],"temperature":0,"max_tokens":16}')"
printf '%s' "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("model") == "exocortex-chat-fast" and d.get("choices")' \
  || { echo 'Default route did not return a valid fast-model completion.' >&2; exit 1; }

quality_response="$(curl -fsS --max-time 180 "http://$bind:$port/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"[route:quality] Reply with exactly: QUALITY_OK"}],"temperature":0,"max_tokens":16}')"
printf '%s' "$quality_response" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("model") == "exocortex-agent-quality" and d.get("choices")' \
  || { echo 'Quality override did not return a valid 27B-model completion.' >&2; exit 1; }
echo 'PASS: loopback binding, readiness, default-fast route, and explicit-quality route.'
