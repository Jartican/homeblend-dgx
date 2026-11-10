#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
set -a
# shellcheck disable=SC1090
. "$CONFIG_DIR/bootstrap.env"
set +a

chat_request="${1:-/tmp/test-fast-chat.json}"
tool_request="${2:-/tmp/test-fast-tool.json}"
auth_header="Authorization: Bearer $LITELLM_KEY"

echo '=== ROUTES ==='
curl -fsS -H "$auth_header" http://127.0.0.1:4000/v1/models \
  | python3 -c 'import json,sys; print("\n".join(sorted(x["id"] for x in json.load(sys.stdin)["data"])))'

echo '=== CHAT ==='
curl -fsS \
  -o /tmp/fast-chat-response.json \
  -w 'total=%{time_total}s start=%{time_starttransfer}s\n' \
  -H "$auth_header" \
  -H 'Content-Type: application/json' \
  --data-binary "@$chat_request" \
  http://127.0.0.1:4000/v1/chat/completions
python3 -c 'import json; d=json.load(open("/tmp/fast-chat-response.json")); print(d["choices"][0]["message"].get("content"))'

echo '=== TOOL ==='
curl -fsS \
  -o /tmp/fast-tool-response.json \
  -w 'total=%{time_total}s start=%{time_starttransfer}s\n' \
  -H "$auth_header" \
  -H 'Content-Type: application/json' \
  --data-binary "@$tool_request" \
  http://127.0.0.1:4000/v1/chat/completions
python3 - <<'PY'
import json

with open('/tmp/fast-tool-response.json', encoding='utf-8') as handle:
    message = json.load(handle)['choices'][0]['message']
calls = message.get('tool_calls') or []
if not calls:
    raise SystemExit('No structured tool call returned')
for call in calls:
    function = call['function']
    print(function['name'], function['arguments'])
PY
