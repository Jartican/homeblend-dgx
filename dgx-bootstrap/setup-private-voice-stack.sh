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

if [[ "${1:-}" == --status ]]; then
  exec "$SCRIPT_DIR/voice-stack-status.sh"
fi
[[ $# -eq 0 ]] || { echo 'Usage: setup-private-voice-stack.sh [--status]' >&2; exit 1; }

if [[ "${DEPLOY_SERVER_DENOISER:-1}" == 1 ]]; then
  "$SCRIPT_DIR/setup-server-denoiser.sh"
fi
if [[ "${DEPLOY_NEURAL_WAKE:-1}" == 1 ]]; then
  "$SCRIPT_DIR/setup-neural-wake.sh"
fi
"$SCRIPT_DIR/setup-private-voice.sh"

if [[ "${DEPLOY_SPEAKER_AWARENESS:-0}" == 1 ]]; then
  if [[ ! -f /etc/exocortex/biometric-vault.conf ]]; then
    echo 'Speaker awareness requires one interactive encrypted-vault step:' >&2
    echo "  sudo $SCRIPT_DIR/create-biometric-vault.sh" >&2
    echo 'Rerun this same command afterward.' >&2
    exit 2
  fi
  if ! findmnt -n -o SOURCE -T /var/lib/exocortex/biometrics | grep -Fxq /dev/mapper/exocortex-biometrics; then
    echo 'The biometric vault exists but is locked. Run:' >&2
    echo "  sudo $SCRIPT_DIR/unlock-biometric-vault.sh" >&2
    echo 'Rerun this same command afterward.' >&2
    exit 2
  fi
  "$SCRIPT_DIR/setup-speaker-awareness.sh"
fi
if [[ "${DEPLOY_SORTFORMER_DIARIZATION:-0}" == 1 ]]; then
  "$SCRIPT_DIR/setup-sortformer-diarization.sh"
fi

"$SCRIPT_DIR/voice-stack-status.sh"
