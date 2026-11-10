#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER="${SPEAKER_CONTAINER:-exocortex-speaker-verifier}"
health="$(docker exec "$CONTAINER" python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8000/health", timeout=10).read().decode())')"
HEALTH="$health" python3 - <<'PY'
import json, os
health = json.loads(os.environ["HEALTH"])
assert health["status"] == "ok", health
assert health["model"] == "titanet_large", health
assert health["raw_audio_persistence"] is False, health
assert health["encrypted_vault_ready"] is True, health
print("TitaNet service contract passed:", health)
PY

docker exec "$CONTAINER" python -m unittest discover -s /app/tests -v
echo 'Live enrollment/verification intentionally requires fresh microphone samples.'
