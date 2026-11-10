#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/share/exocortex-delegate"
SOURCE="$SCRIPT_DIR/codex-delegation/delegate_fast_remote.py"

[[ -r "$HOME/.config/exocortex/stack.env" ]] || {
  echo 'Missing ~/.config/exocortex/stack.env; run the main bootstrap first.' >&2
  exit 1
}
mkdir -p "$INSTALL_DIR"
install -m 0700 "$SOURCE" "$INSTALL_DIR/delegate_fast_remote.py"
echo "Installed non-persisting Codex delegate helper: $INSTALL_DIR/delegate_fast_remote.py"
