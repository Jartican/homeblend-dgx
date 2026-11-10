#!/usr/bin/env python3
"""Pin the signed iPhone build to one exact Tailscale Serve hostname."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import tempfile


HOST_PATTERN = re.compile(
    r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.tail[a-z0-9]+\.ts\.net$"
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hostname", help="exact MagicDNS HTTPS hostname from `tailscale serve status`")
    args = parser.parse_args()
    hostname = args.hostname.strip().lower().rstrip(".")
    if not HOST_PATTERN.fullmatch(hostname):
        raise SystemExit("hostname must be one exact <device>.tail<id>.ts.net name")

    project = Path(__file__).resolve().parent / "project.yml"
    source = project.read_text(encoding="utf-8")
    pattern = re.compile(r"^(\s*VOICE_CORE_HOST:\s*).+$", re.MULTILINE)
    if len(pattern.findall(source)) != 1:
        raise SystemExit("project.yml must contain exactly one VOICE_CORE_HOST setting")
    updated = pattern.sub(lambda match: match.group(1) + hostname, source)
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=project.parent, prefix=".project-", delete=False
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(updated)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_name, project)
    finally:
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass
    print(f"Pinned signed HomeBlend app endpoint to: {hostname}")


if __name__ == "__main__":
    main()
