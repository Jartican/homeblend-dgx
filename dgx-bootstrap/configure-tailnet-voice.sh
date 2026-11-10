#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }

CONFIG_DIR="${EXOCORTEX_CONFIG_DIR:-${SUDO_USER:+/home/$SUDO_USER}/.config/exocortex}"
ENV_FILE="$CONFIG_DIR/stack.env"
if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi
: "${VOICE_GATEWAY_PORT:=8791}"

health_json="$(curl -fsS "http://127.0.0.1:$VOICE_GATEWAY_PORT/health")" || {
  echo "Voice gateway is not healthy on loopback port $VOICE_GATEWAY_PORT." >&2
  echo 'Run setup-private-voice.sh as the Exocortex user first.' >&2
  exit 1
}
python3 -c '
import json, sys
state = json.load(sys.stdin).get("security", {}).get("application_auth", {})
if state.get("production_ready") is not True:
    mode = state.get("mode", "unknown")
    bridge = state.get("compatibility_bridge")
    raise SystemExit(
        "Refusing tailnet publication: Voice Core application auth is not production-ready "
        f"(mode={mode}, bridge={bridge})."
    )
' <<<"$health_json"

# Invoke the installed launcher as-is. The Snap launcher injects its private
# socket automatically; adding --socket here passes the flag twice. Native
# package installations already default to /var/run/tailscale/tailscaled.sock.
tailscale_cli=(tailscale)

"${tailscale_cli[@]}" serve --bg --set-path=/voice "http://127.0.0.1:$VOICE_GATEWAY_PORT"
status="$("${tailscale_cli[@]}" serve status)"
printf '%s\n' "$status"
grep -Fq '(tailnet only)' <<<"$status" || {
  echo 'Refusing to claim success: Tailscale did not report tailnet-only access.' >&2
  exit 1
}
grep -Fq '/voice' <<<"$status" || {
  echo 'Refusing to claim success: /voice is missing from Tailscale Serve.' >&2
  exit 1
}

echo 'Private phone client configured. This script never enables Tailscale Funnel.'
