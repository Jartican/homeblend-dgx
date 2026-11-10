#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE" >&2; exit 1; }

usage() {
  echo 'Usage: configure-private-voice-features.sh [--wake on|off] [--denoiser on|off] [--speaker on|off] [--diarization on|off] [--realtime on|off]'
}

set_value() {
  local key="$1" value="$2" temporary
  [[ "$value" == on || "$value" == off ]] || { echo "$key expects on or off" >&2; exit 2; }
  [[ "$value" == on ]] && value=1 || value=0
  temporary="$(mktemp "$CONFIG_DIR/stack.env.XXXXXX")"
  awk -v key="$key" -v value="$value" '
    BEGIN { found=0 }
    $0 ~ "^" key "=" { print key "=" value; found=1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$ENV_FILE" >"$temporary"
  chmod --reference="$ENV_FILE" "$temporary"
  mv -f -- "$temporary" "$ENV_FILE"
}

[[ $# -gt 0 ]] || { usage; grep -E '^(DEPLOY_(NEURAL_WAKE|SERVER_DENOISER|SPEAKER_AWARENESS|SORTFORMER_DIARIZATION)|VOICE_REALTIME_ENABLED)=' "$ENV_FILE" || true; exit 0; }
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || { usage >&2; exit 2; }
  case "$1" in
    --wake) set_value DEPLOY_NEURAL_WAKE "$2" ;;
    --denoiser) set_value DEPLOY_SERVER_DENOISER "$2" ;;
    --speaker) set_value DEPLOY_SPEAKER_AWARENESS "$2" ;;
    --diarization) set_value DEPLOY_SORTFORMER_DIARIZATION "$2" ;;
    --realtime) set_value VOICE_REALTIME_ENABLED "$2" ;;
    *) usage >&2; exit 2 ;;
  esac
  shift 2
done
grep -E '^(DEPLOY_(NEURAL_WAKE|SERVER_DENOISER|SPEAKER_AWARENESS|SORTFORMER_DIARIZATION)|VOICE_REALTIME_ENABLED)=' "$ENV_FILE"
