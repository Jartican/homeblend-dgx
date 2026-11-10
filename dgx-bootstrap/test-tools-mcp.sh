#!/usr/bin/env bash
set -Eeuo pipefail

docker inspect exocortex-searxng exocortex-mcp-gateway >/dev/null
[[ "$(docker inspect exocortex-searxng --format '{{.State.Health.Status}}')" == healthy ]]
[[ "$(docker inspect exocortex-mcp-gateway --format '{{.State.Health.Status}}')" == healthy ]]
docker exec exocortex-mcp-gateway python /app/test_mcp.py http://127.0.0.1:8000/mcp
