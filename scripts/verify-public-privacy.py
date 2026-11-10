#!/usr/bin/env python3
"""Reject common personal or operational identifiers in a public release."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess


RULES = {
    "windows-user-path": re.compile(rb"[A-Za-z]:\\Users\\[^\\\r\n]+", re.I),
    "ssn": re.compile(rb"(?<![0-9])[0-9]{3}-[0-9]{2}-[0-9]{4}(?![0-9])"),
    "us-phone": re.compile(
        rb"(?<![0-9])(?:\+?1[-. ]?)?\(?[2-9][0-9]{2}\)?[-. ][0-9]{3}[-. ][0-9]{4}(?![0-9])"
    ),
    "private-ip": re.compile(
        rb"(?<![0-9])(?:10\.(?:[0-9]{1,3}\.){2}[0-9]{1,3}|"
        rb"192\.168\.(?:[0-9]{1,3}\.)[0-9]{1,3}|"
        rb"100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\."
        rb"[0-9]{1,3}\.[0-9]{1,3})(?![0-9])"
    ),
}
EMAIL = re.compile(rb"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", re.I)
TAILNET = re.compile(rb"[A-Za-z0-9.-]+\.ts\.net", re.I)
MAX_FILE_BYTES = 5 * 1024 * 1024


def candidates(root: Path) -> list[Path]:
    completed = subprocess.run(
        ["git", "ls-files", "-z"], cwd=root, check=False, capture_output=True
    )
    if completed.returncode == 0:
        return [root / value.decode("utf-8") for value in completed.stdout.split(b"\0") if value]
    return [path for path in root.rglob("*") if path.is_file()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    root = args.root.resolve()
    findings: set[tuple[str, str]] = set()

    for path in candidates(root):
        relative = path.relative_to(root).as_posix()
        try:
            if path.stat().st_size > MAX_FILE_BYTES:
                continue
            content = path.read_bytes()
        except OSError:
            findings.add((relative, "unreadable-file"))
            continue
        if b"\0" in content[:8192]:
            continue
        for name, pattern in RULES.items():
            if pattern.search(content):
                findings.add((relative, name))
        for match in EMAIL.finditer(content):
            value = match.group(0).lower()
            if b"example" not in value and not value.endswith(
                (b".invalid", b"@users.noreply.github.com")
            ):
                findings.add((relative, "email-address"))
        for match in TAILNET.finditer(content):
            if b"example" not in match.group(0).lower():
                findings.add((relative, "tailnet-hostname"))

    for path, rule in sorted(findings):
        print(f"{path}: {rule}")
    if findings:
        print(f"Public privacy scan failed with {len(findings)} finding(s).")
        return 1
    print("Public privacy scan passed: no candidate personal deployment identifiers detected.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
