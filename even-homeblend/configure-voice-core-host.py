#!/usr/bin/env python3
"""Pin one exact tailnet Voice Core host before packaging the Even client."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re


HOST_PATTERN = re.compile(
    r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.tail[a-z0-9]+\.ts\.net$"
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hostname", help="exact MagicDNS host from `tailscale serve status`")
    hostname = parser.parse_args().hostname.strip().lower().rstrip(".")
    if not HOST_PATTERN.fullmatch(hostname):
        raise SystemExit("hostname must be one exact <device>.tail<id>.ts.net name")

    root = Path(__file__).resolve().parent
    manifest_path = root / "app.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    network = next(
        (item for item in manifest.get("permissions", []) if item.get("name") == "network"),
        None,
    )
    if network is None:
        raise SystemExit("app.json is missing the network permission")
    network["whitelist"] = [f"https://{hostname}", f"wss://{hostname}"]
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    (root / ".env.local").write_text(
        f"VITE_VOICE_GATEWAY_URL=wss://{hostname}/voice/v2/voice/realtime\n",
        encoding="utf-8",
    )
    print(f"Pinned Even package endpoint to: {hostname}")


if __name__ == "__main__":
    main()
