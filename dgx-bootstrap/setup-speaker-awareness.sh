#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${OPEN_WEBUI_NETWORK:=exocortex-tools}"
: "${EXOCORTEX_VOICE_NETWORK:=exocortex-voice}"
: "${SPEAKER_CONTAINER:=exocortex-speaker-verifier}"
: "${EXOCORTEX_BIOMETRIC_CONFIG_FILE:=/etc/exocortex/biometric-vault.conf}"

[[ -r "$EXOCORTEX_BIOMETRIC_CONFIG_FILE" ]] || {
  echo 'Encrypted biometric vault has not been created. Run:' >&2
  echo "  sudo $SCRIPT_DIR/create-biometric-vault.sh" >&2
  exit 2
}
sudo "$SCRIPT_DIR/verify-biometric-vault.sh"
docker network inspect "$OPEN_WEBUI_NETWORK" >/dev/null
docker network inspect "$EXOCORTEX_VOICE_NETWORK" >/dev/null

docker compose --env-file "$ENV_FILE" --file "$SCRIPT_DIR/compose.speaker.yaml" \
  up --detach --build speaker-verifier

echo 'Waiting for TitaNet to download and load on CPU...'
for _ in $(seq 1 240); do
  state="$(docker inspect "$SPEAKER_CONTAINER" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  [[ "$state" == healthy ]] && break
  [[ "$state" == exited || "$state" == dead ]] && {
    docker logs --tail 150 "$SPEAKER_CONTAINER" >&2
    exit 1
  }
  sleep 5
done
[[ "$(docker inspect "$SPEAKER_CONTAINER" --format '{{.State.Health.Status}}')" == healthy ]] || {
  docker logs --tail 150 "$SPEAKER_CONTAINER" >&2
  echo 'TitaNet speaker service did not become healthy.' >&2
  exit 1
}

# The model is cached inside the encrypted vault. Remove ordinary internet
# egress after first successful load; the internal voice network remains.
if docker inspect "$SPEAKER_CONTAINER" --format '{{json .NetworkSettings.Networks}}' | grep -Fq "\"$OPEN_WEBUI_NETWORK\""; then
  docker network disconnect "$OPEN_WEBUI_NETWORK" "$SPEAKER_CONTAINER"
fi

speaker_ip="$(docker inspect "$SPEAKER_CONTAINER" \
  --format "{{with index .NetworkSettings.Networks \"$EXOCORTEX_VOICE_NETWORK\"}}{{.IPAddress}}{{end}}")"
[[ -n "$speaker_ip" ]] || { echo 'Could not resolve speaker service address.' >&2; exit 1; }
echo "TitaNet is healthy on the internal-only address http://$speaker_ip:8000."
echo 'No speaker profile has been enrolled yet.'
if docker container inspect "${VOICE_GATEWAY_CONTAINER:-exocortex-voice-gateway}" >/dev/null 2>&1; then
  "$SCRIPT_DIR/setup-private-voice.sh"
fi
echo 'Enroll through the private /voice/speaker page; the speaker API has no host port.'
