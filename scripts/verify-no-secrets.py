#!/usr/bin/env python3
"""Fail when Git candidate files contain likely credentials or private keys.

The report intentionally prints only path, line number, and rule name. It never
echoes a matched value, making it safe to use before commits and in CI logs.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys


HIGH_CONFIDENCE_RULES = {
    "private-key-block": re.compile(rb"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
    "tailscale-auth-key": re.compile(rb"\btskey-(?:auth|client|api)-[A-Za-z0-9_-]{16,}"),
    "aws-access-key": re.compile(rb"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
    "github-token": re.compile(rb"\bgh[opusr]_[A-Za-z0-9]{20,}\b"),
    "huggingface-token": re.compile(rb"\bhf_[A-Za-z0-9]{20,}\b"),
    "openai-style-key": re.compile(rb"\bsk-[A-Za-z0-9_-]{20,}\b"),
}
ASSIGNMENT = re.compile(
    rb"(?i)\b(password|passwd|api[_-]?key|auth[_-]?token|access[_-]?token|"
    rb"secret|private[_-]?key)\b\s*[:=]\s*[\"']?([^\s\"'#,;]+)"
)
FORBIDDEN_NAMES = {
    ".env",
    "stack.env",
    "gateway.env",
    "clients.json",
    "id_rsa",
    "id_ed25519",
}
FORBIDDEN_SUFFIXES = {".key", ".p12", ".pfx", ".mobileprovision"}
MAX_FILE_BYTES = 5 * 1024 * 1024


def git_candidates(root: Path) -> list[Path]:
    completed = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
        check=False,
        capture_output=True,
    )
    if completed.returncode != 0:
        # Release archives intentionally contain no .git directory. Every file
        # in such an export came from the already-curated Git tree, so scan the
        # complete archive instead of silently skipping validation.
        return [path for path in root.rglob("*") if path.is_file()]
    return [root / value.decode("utf-8") for value in completed.stdout.split(b"\0") if value]


def placeholder(value: bytes) -> bool:
    lowered = value.lower()
    prefixes = (
        b"replace-", b"change-", b"example", b"placeholder", b"test-",
        b"dummy", b"local-", b"${", b"$", b"<", b"{{", b"none",
        b"null", b"false", b"true", b"os.environ", b"getenv(",
    )
    return not value or lowered.startswith(prefixes)


def looks_random(value: bytes) -> bool:
    if len(value) < 20:
        return False
    classes = sum((
        any(65 <= byte <= 90 for byte in value),
        any(97 <= byte <= 122 for byte in value),
        any(48 <= byte <= 57 for byte in value),
        any(byte in b"-_=+/" for byte in value),
    ))
    return classes >= 3


def line_number(content: bytes, offset: int) -> int:
    return content.count(b"\n", 0, offset) + 1


def scan(path: Path, root: Path) -> list[tuple[str, int, str]]:
    relative = path.relative_to(root).as_posix()
    findings: list[tuple[str, int, str]] = []
    lowered_name = path.name.lower()
    if (
        lowered_name in FORBIDDEN_NAMES
        or path.suffix.lower() in FORBIDDEN_SUFFIXES
        or lowered_name.startswith("id_rsa")
        or lowered_name.startswith("id_ed25519")
    ):
        findings.append((relative, 0, "forbidden-secret-filename"))
    try:
        if not path.is_file() or path.stat().st_size > MAX_FILE_BYTES:
            return findings
        content = path.read_bytes()
    except OSError:
        findings.append((relative, 0, "unreadable-file"))
        return findings
    if b"\0" in content[:8192]:
        return findings
    for rule, pattern in HIGH_CONFIDENCE_RULES.items():
        for match in pattern.finditer(content):
            findings.append((relative, line_number(content, match.start()), rule))
    for match in ASSIGNMENT.finditer(content):
        value = match.group(2).rstrip(b")]}>")
        if not placeholder(value) and looks_random(value):
            findings.append((
                relative,
                line_number(content, match.start()),
                "high-entropy-secret-assignment",
            ))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    root = args.root.resolve()
    findings = [finding for path in git_candidates(root) for finding in scan(path, root)]
    for path, line, rule in sorted(set(findings)):
        location = f"{path}:{line}" if line else path
        print(f"{location}: {rule}")
    if findings:
        print(f"Secret scan failed with {len(set(findings))} finding(s).", file=sys.stderr)
        return 1
    print("Secret scan passed: no candidate credentials or private keys detected.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
