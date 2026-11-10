#!/usr/bin/env bash
set -Eeuo pipefail
set -a; . "${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}/gateway.env"; set +a
python_bin="$HOME/.local/share/exocortex-gateway-venv/bin/python"
"$python_bin" - <<'PY'
import json, os, httpx
payload={"model":"exocortex-smart","max_tokens":32,"stream":False,"messages":[{"role":"user","content":"Reply exactly SMART_FAST_OK"}]}
r=httpx.post("http://127.0.0.1:4011/v1/messages",headers={"x-api-key":os.environ["EXOCORTEX_CLAUDE_ROUTER_KEY"],"anthropic-version":"2023-06-01"},json=payload,timeout=120)
print("status",r.status_code)
print("selected",r.headers.get("x-exocortex-selected-model"))
print("reason",r.headers.get("x-exocortex-routing-reason"))
print(json.dumps(r.json(),indent=2)[:4000])
r.raise_for_status()
PY
