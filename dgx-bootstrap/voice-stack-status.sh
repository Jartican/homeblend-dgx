#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-$HOME/.config/exocortex}"
if [[ -f "$CONFIG_DIR/stack.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$CONFIG_DIR/stack.env"
  set +a
fi

container_state() {
  docker inspect "$1" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo absent
}

echo 'Exocortex private voice feature status'
echo "STT/TTS service:             $(container_state "${SPEACHES_CONTAINER:-exocortex-speaches}")"
echo "Voice/wake gateway:          $(container_state "${VOICE_GATEWAY_CONTAINER:-exocortex-voice-gateway}")"
echo "Neural wake service:         $(container_state "${NEURAL_WAKE_CONTAINER:-exocortex-neural-wake}")"
echo "DeepFilterNet denoiser:      $(container_state "${DENOISER_CONTAINER:-exocortex-denoiser}")"
echo "TitaNet speaker service:     $(container_state "${SPEAKER_CONTAINER:-exocortex-speaker-verifier}")"
echo "Sortformer diarization:      $(container_state "${DIARIZATION_CONTAINER:-exocortex-diarization}")"
if findmnt -n -o SOURCE -T /var/lib/exocortex/biometrics 2>/dev/null | grep -Fxq /dev/mapper/exocortex-biometrics; then
  echo 'Encrypted biometric vault:  mounted'
else
  echo 'Encrypted biometric vault:  absent or locked'
fi
echo 'Wake implementation:         sherpa-onnx neural KWS; Whisper only after a hit'
echo 'Browser noise suppression:   requested from WebRTC client'
echo 'Server noise suppression:    DeepFilterNet3 when service is healthy'
echo 'Diarization policy:          opt-in per request; participant consent required'
echo 'See config/voice-stack.yaml for machine-readable assumptions.'
