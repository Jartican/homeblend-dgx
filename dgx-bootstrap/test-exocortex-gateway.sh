#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
GATEWAY_ENV="$CONFIG_DIR/gateway.env"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-spark-postgres}"

[[ -r "$GATEWAY_ENV" ]] || { echo "Missing $GATEWAY_ENV" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$GATEWAY_ENV"
set +a

gateway_url="http://${EXOCORTEX_GATEWAY_HOST:-127.0.0.1}:${EXOCORTEX_GATEWAY_PORT:-4010}"
payload_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f "$payload_file" "$response_file"' EXIT

cat >"$payload_file" <<'JSON'
{
  "model": "ignored-by-router",
  "stream": false,
  "messages": [
    {
      "role": "user",
      "content": "SYNTHETIC TEST ONLY. Reply with exactly: SYNTHETIC_OK"
    }
  ]
}
JSON

echo '=== Health ==='
curl -fsS "$gateway_url/health"
echo

echo '=== Route preview ==='
curl -fsS "$gateway_url/v1/route" \
  -H "Authorization: Bearer $EXOCORTEX_GATEWAY_KEY" \
  -H 'Content-Type: application/json' \
  --data-binary "@$payload_file"
echo

echo '=== Synthetic chat ==='
curl -fsS "$gateway_url/v1/chat/completions" \
  -H "Authorization: Bearer $EXOCORTEX_GATEWAY_KEY" \
  -H 'Content-Type: application/json' \
  -H 'X-Exocortex-Client-Type: synthetic-test' \
  --data-binary "@$payload_file" >"$response_file"

python3 - "$response_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    response = json.load(handle)

summary = {
    "content": response["choices"][0]["message"]["content"],
    "model": response.get("model"),
    "exocortex": response.get("exocortex"),
}
print(json.dumps(summary, indent=2))
PY

echo '=== Joined log row ==='
docker exec "$POSTGRES_CONTAINER" psql -U exocortex -d exocortex -P pager=off -c \
  "SELECT request_at, user_request, dgx_response, selected_route,
          assigned_effort, latency_ms, input_tokens, output_tokens
     FROM exocortex_raw.full_turn_context
    WHERE client_type = 'synthetic-test'
    ORDER BY request_at DESC
    LIMIT 1;"
