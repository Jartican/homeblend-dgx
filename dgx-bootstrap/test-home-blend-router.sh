#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
set -a; . "$CONFIG_DIR/gateway.env"; set +a
bridge_ip="${EXOCORTEX_DOCKER_BRIDGE_IP:-$(ip -4 -o addr show docker0 | awk '{split($4,a,"/"); print a[1]; exit}')}"
base="http://$bridge_ip:4012"
auth="Authorization: Bearer $EXOCORTEX_HOME_ROUTER_KEY"

curl -fsS "$base/health"
curl -fsS "$base/v1/models" -H "$auth"

fast_headers="$(mktemp)"
quality_headers="$(mktemp)"
vision_headers="$(mktemp)"
trap 'rm -f -- "$fast_headers" "$quality_headers" "$vision_headers"' EXIT
curl -fsS -D "$fast_headers" "$base/v1/chat/completions" -H "$auth" -H 'Content-Type: application/json' \
  --data-binary '{"model":"exocortex-home-blend","messages":[{"role":"user","content":"Reply exactly BLEND_FAST_OK"}],"max_tokens":32}' >/dev/null
grep -Fiq 'x-exocortex-selected-model: exocortex-chat-fast' "$fast_headers"

curl -fsS -D "$quality_headers" "$base/v1/chat/completions" -H "$auth" -H 'Content-Type: application/json' \
  --data-binary '{"model":"exocortex-home-blend","messages":[{"role":"user","content":"This is an architecture decision. Reply exactly BLEND_QUALITY_OK"}],"max_tokens":32}' >/dev/null
grep -Fiq 'x-exocortex-selected-model: exocortex-agent-quality' "$quality_headers"

curl -fsS -D "$vision_headers" "$base/v1/chat/completions" -H "$auth" -H 'Content-Type: application/json' \
  --data-binary '{"model":"exocortex-home-blend","messages":[{"role":"user","content":[{"type":"text","text":"Reply exactly BLEND_VISION_OK"},{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl9sAAAAASUVORK5CYII="}}]}],"max_tokens":32}' >/dev/null
grep -Fiq 'x-exocortex-selected-model: exocortex-agent-quality' "$vision_headers"

docker exec open-webui curl -fsS "$base/v1/models" -H "$auth" >/dev/null
echo 'Home blend fast, quality, vision, and Open WebUI-container connectivity: pass'
