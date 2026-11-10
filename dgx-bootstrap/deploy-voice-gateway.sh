#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --mode compatibility|production" >&2
}

mode=""
while (($#)); do
  case "$1" in
    --mode)
      mode="${2:-}"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ "$mode" != "compatibility" && "$mode" != "production" ]]; then
  usage
  exit 2
fi

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
stack_env="${HOME}/.config/exocortex/stack.env"
registry_host="${HOME}/.config/homeblend/voice-core/clients.json"
registry_container="/run/secrets/homeblend/clients.json"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
[[ -f "$stack_env" ]] || { echo "missing stack environment: $stack_env" >&2; exit 1; }

set_stack_value() {
  local key="$1" value="$2" temporary
  temporary="$(mktemp "${stack_env}.XXXXXX")"
  awk -v key="$key" -v value="$value" '
    BEGIN { found=0 }
    $0 ~ "^" key "=" { print key "=" value; found=1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$stack_env" >"$temporary"
  chmod --reference="$stack_env" "$temporary"
  mv -f -- "$temporary" "$stack_env"
}

container_ip() {
  local container="$1"
  local address
  address="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container")"
  [[ "$address" =~ ^[0-9]+.[0-9]+.[0-9]+.[0-9]+$ ]] || {
    echo "could not discover a private address for $container" >&2
    exit 1
  }
  printf '%s' "$address"
}

speaches="$(container_ip exocortex-speaches)"
speaker="$(container_ip exocortex-speaker-verifier)"
wake="$(container_ip exocortex-neural-wake)"
denoiser="$(container_ip exocortex-denoiser)"
diarization="$(container_ip exocortex-diarization)"

export VOICE_SPEACHES_URL="http://${speaches}:8000/v1"
export VOICE_SPEAKER_URL="http://${speaker}:8000/v1/speaker"
export VOICE_NEURAL_WAKE_URL="http://${wake}:8000"
export VOICE_DENOISER_URL="http://${denoiser}:8000"
export VOICE_DIARIZATION_URL="http://${diarization}:8000"
export VOICE_REALTIME_ENABLED=1
export VOICE_REALTIME_CLIENT_TOKEN_SHA256=""

if [[ -f "$registry_host" ]]; then
  PYTHONPATH="$root/voice-gateway" python3 -c \
    'import sys; from realtime_auth import load_client_registry; clients=load_client_registry(sys.argv[1]); print(f"Validated {len(clients)} Voice Core client(s).")' \
    "$registry_host"
  export VOICE_REALTIME_CLIENT_REGISTRY="$registry_container"
else
  export VOICE_REALTIME_CLIENT_REGISTRY=""
fi

if [[ "$mode" == "compatibility" ]]; then
  export VOICE_REALTIME_ALLOW_TAILNET_UNAUTHENTICATED=true
else
  [[ -f "$registry_host" ]] || {
    echo "production mode requires an enrolled client registry: $registry_host" >&2
    exit 1
  }
  export VOICE_REALTIME_ALLOW_TAILNET_UNAUTHENTICATED=false
  # Persist only non-secret server mode. The raw token remains solely in the
  # phone Keychain; this path points to the hash-only registry bind mount.
  set_stack_value VOICE_REALTIME_CLIENT_REGISTRY "$registry_container"
  set_stack_value VOICE_REALTIME_CLIENT_TOKEN_SHA256 ""
  set_stack_value VOICE_REALTIME_ALLOW_TAILNET_UNAUTHENTICATED false
fi

cd "$root"
docker compose --env-file "$stack_env" -f compose.voice.yaml \
  up -d --no-deps --build voice-gateway

echo "Voice Core deployed in ${mode} mode."
docker inspect exocortex-voice-gateway --format \
  '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E '^VOICE_REALTIME_(ENABLED|ALLOW_TAILNET_UNAUTHENTICATED|CLIENT_REGISTRY|MAX_SESSION_SECONDS)='
