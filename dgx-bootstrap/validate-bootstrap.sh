#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for command in bash docker python3 grep sed; do
  command -v "$command" >/dev/null || {
    echo "Missing validation command: $command" >&2
    exit 1
  }
done
docker compose version >/dev/null

echo '=== Shell syntax ==='
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find "$SCRIPT_DIR" -type f -name '*.sh' -print0)
echo 'shell syntax: pass'

echo '=== Python and JSON syntax ==='
python3 - "$SCRIPT_DIR" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
for path in root.rglob("*.py"):
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
for path in root.rglob("*.json"):
    with path.open(encoding="utf-8") as handle:
        json.load(handle)

webui_setup = (root / "setup-open-webui.sh").read_text(encoding="utf-8")
match = re.search(r'^(\[\{"type":"mcp".*\}\])$', webui_setup, re.MULTILINE)
if not match:
    raise SystemExit("Open WebUI MCP declaration was not found")
connection = json.loads(match.group(1))[0]
assert connection["type"] == "mcp"
assert connection["auth_type"] == "none"
assert connection["config"]["enable"] is True
assert connection["info"]["id"] == "exocortex"
PY
echo 'Python and JSON syntax: pass'

echo '=== Canonical clean-install invariants ==='
grep -Fq 'MCP_GATEWAY_PORT=8766' "$SCRIPT_DIR/config/stack.example.env"
grep -Fq 'VLLM_MODEL_SOURCE=nvidia/Qwen3-8B-NVFP4' "$SCRIPT_DIR/config/stack.example.env"
grep -Fq 'VLLM_SERVED_MODEL=exocortex-chat-fast' "$SCRIPT_DIR/config/stack.example.env"
grep -Fq 'OPEN_WEBUI_MCP_URL=http://exocortex-mcp-gateway:8000/mcp' \
  "$SCRIPT_DIR/config/stack.example.env"
grep -Fq 'TOOL_SERVER_CONNECTIONS=' "$SCRIPT_DIR/setup-open-webui.sh"
grep -Fq 'deploy-claude-smart-router.sh' "$SCRIPT_DIR/bootstrap-dgx.sh"
grep -Fq 'deploy-home-blend-router.sh' "$SCRIPT_DIR/bootstrap-dgx.sh"
grep -Fq 'test-home-blend-router.sh' "$SCRIPT_DIR/bootstrap-dgx.sh"
grep -Fq 'deploy-codex-fast-delegate.sh' "$SCRIPT_DIR/bootstrap-dgx.sh"
test -f "$SCRIPT_DIR/clients/claude-dgx.ps1"
test -f "$SCRIPT_DIR/clients/exocortex_fast_mcp.py"
test -f "$SCRIPT_DIR/setup-coding-lab.sh"
test -f "$SCRIPT_DIR/run-coding-lab.sh"
test -f "$SCRIPT_DIR/run-coding-canary.sh"
test -f "$SCRIPT_DIR/deploy-home-blend-router.sh"
test -f "$SCRIPT_DIR/test-home-blend-router.sh"
test -f "$SCRIPT_DIR/setup-homeblend-harness.sh"
test -f "$SCRIPT_DIR/setup-private-voice-stack.sh"
test -f "$SCRIPT_DIR/configure-tailnet-voice.sh"
test -f "$SCRIPT_DIR/compose.harness.yaml"
test -f "$SCRIPT_DIR/compose.voice.yaml"
test -f "$SCRIPT_DIR/voice-speech/Dockerfile"
test -f "$SCRIPT_DIR/wake-service/Dockerfile"
test -f "$SCRIPT_DIR/denoise-service/Dockerfile"
test -f "$SCRIPT_DIR/manage-voice-clients.py"
test -f "$SCRIPT_DIR/enroll-phone-client.sh"
test -f "$SCRIPT_DIR/../omi-phone-app/project.yml"
test -f "$SCRIPT_DIR/../omi_homeblend/storage/001_private_assistant.sql"
test -f "$SCRIPT_DIR/../experiments/offload_lab/suites/exocortex-coding-core-v0.1.json"

if grep -R -n -E 'MCP_GATEWAY_PORT:-8765|MCP_GATEWAY_PORT=8765|127\.0\.0\.1:8765/mcp' \
    "$SCRIPT_DIR/bootstrap-dgx.sh" \
    "$SCRIPT_DIR/setup-tools-mcp.sh" \
    "$SCRIPT_DIR/setup-open-webui.sh" \
    "$SCRIPT_DIR/compose.tools.yaml" \
    "$SCRIPT_DIR/config/stack.example.env"; then
  echo 'Retired MCP port found in the clean-install path.' >&2
  exit 1
fi

if grep -R -n -E 'sk-local-dgx|memo[-_ ]?os|memo-chat-fast|memo-agent-quality' \
    "$SCRIPT_DIR/bootstrap-dgx.sh" \
    "$SCRIPT_DIR/setup-"*.sh \
    "$SCRIPT_DIR/compose.tools.yaml" \
    "$SCRIPT_DIR/config"; then
  echo 'Retired identifier or weak default secret found in the clean-install path.' >&2
  exit 1
fi
grep -Fq 'DEPLOY_PRIVATE_VOICE_STACK=1' "$SCRIPT_DIR/config/stack.example.env"
grep -Fq 'VOICE_REALTIME_ALLOW_TAILNET_UNAUTHENTICATED=false' \
  "$SCRIPT_DIR/config/stack.example.env"
grep -Fq 'setup-homeblend-harness.sh' "$SCRIPT_DIR/bootstrap-dgx.sh"
grep -Fq 'setup-private-voice-stack.sh' "$SCRIPT_DIR/bootstrap-dgx.sh"
grep -Fq 'protected_http_route' "$SCRIPT_DIR/voice-gateway/server.py"
grep -Fq 'production_ready' "$SCRIPT_DIR/configure-tailnet-voice.sh"
grep -Fq 'voice audit sink unavailable' "$SCRIPT_DIR/voice-gateway/server.py"
grep -Fq 'VOICE_CORE_HOST: voice-core.invalid' "$SCRIPT_DIR/../omi-phone-app/project.yml"
grep -Fq 'wss://voice-core.invalid' "$SCRIPT_DIR/../even-homeblend/app.json"
if grep -R -n -E '[[:alnum:]-]+\.[[:alnum:]-]+\.ts\.net|/home/[[:alnum:]_-]+|C:\\Users\\[[:alnum:]_.-]+' \
    "$SCRIPT_DIR/../phone-voice-smoke" \
    "$SCRIPT_DIR/../omi-phone-app/Sources" \
    "$SCRIPT_DIR/../even-homeblend/src" \
    "$SCRIPT_DIR/../even-homeblend/app.json" \
    "$SCRIPT_DIR/clients"; then
  echo 'Concrete machine-specific host, home path, or Windows user path found in a deployable client path.' >&2
  exit 1
fi
if grep -Rq 'SGLANG_PORT' "$SCRIPT_DIR/compose.harness.yaml"; then
  echo 'Fresh HomeBlend harness still depends on the legacy SGLang listener.' >&2
  exit 1
fi
echo 'canonical invariants: pass'

echo '=== Docker Compose render ==='
temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"' EXIT
sed \
  -e 's/replace-with-a-random-local-key/test-litellm-key/' \
  -e 's/replace-with-a-random-password/test-postgres-password/' \
  -e 's/replace-with-a-random-secret/test-generated-secret/g' \
  "$SCRIPT_DIR/config/stack.example.env" >"$temp_dir/stack.env"
docker compose \
  --env-file "$temp_dir/stack.env" \
  --file "$SCRIPT_DIR/compose.tools.yaml" \
  config --quiet
HOME="$temp_dir/home" docker compose \
  --env-file "$temp_dir/stack.env" \
  --file "$SCRIPT_DIR/compose.voice.yaml" \
  config --quiet
for compose_file in compose.wake.yaml compose.denoise.yaml compose.speaker.yaml compose.diarization.yaml; do
  docker compose \
    --env-file "$temp_dir/stack.env" \
    --file "$SCRIPT_DIR/$compose_file" \
    config --quiet
done
printf '\nHOMEBLEND_REPO_PATH=%s\nLOCAL_UID=1000\nLOCAL_GID=1000\n' "$SCRIPT_DIR/.." \
  >>"$temp_dir/stack.env"
docker compose \
  --env-file "$temp_dir/stack.env" \
  --file "$SCRIPT_DIR/compose.harness.yaml" \
  config --quiet
echo 'Docker Compose render: pass'

echo '=== Secret-free repository candidates ==='
if [[ -f "$SCRIPT_DIR/../scripts/verify-no-secrets.py" ]]; then
  python3 "$SCRIPT_DIR/../scripts/verify-no-secrets.py" --root "$SCRIPT_DIR/.."
fi

echo 'Bootstrap validation complete.'
