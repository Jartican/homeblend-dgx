#!/usr/bin/env bash
set -Eeuo pipefail

command -v openssl >/dev/null || { echo 'openssl is required.' >&2; exit 1; }

token="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
hash="$(printf '%s' "$token" | sha256sum | awk '{print $1}')"

cat <<EOF
VOICE CLIENT TOKEN (shown once; store only in the client Keychain/password manager):
$token

SERVER SHA-256 HASH (safe to place in VOICE_REALTIME_CLIENT_TOKEN_SHA256):
$hash
EOF

unset token
