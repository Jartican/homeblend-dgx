#!/usr/bin/env python3
"""Export the explicitly allowed, tracked public HomeBlend release tree."""

from __future__ import annotations

import argparse
import fnmatch
import json
from pathlib import Path
import shutil
import subprocess
import sys


def tracked_files(root: Path) -> list[str]:
    completed = subprocess.run(
        ["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True
    )
    return sorted(
        value.decode("utf-8").replace("\\", "/")
        for value in completed.stdout.split(b"\0")
        if value
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    destination = args.destination.resolve()
    if destination == root or root in destination.parents:
        raise SystemExit("destination must be outside the source repository")
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"destination is not empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)

    policy = json.loads((root / "public-release.json").read_text(encoding="utf-8"))
    allowed_files = set(policy["allowed_files"])
    allowed_directories = tuple(
        value.rstrip("/") + "/" for value in policy["allowed_directories"]
    )
    denied_globs = tuple(policy["denied_globs"])

    selected: list[str] = []
    for relative in tracked_files(root):
        allowed = relative in allowed_files or relative.startswith(allowed_directories)
        denied = any(fnmatch.fnmatch(relative, pattern) for pattern in denied_globs)
        if allowed and not denied:
            selected.append(relative)

    missing = sorted(allowed_files.difference(selected))
    if missing:
        raise SystemExit("allowed file is not tracked: " + ", ".join(missing))

    for relative in selected:
        source = root / relative
        target = destination / relative
        if source.is_symlink():
            raise SystemExit(f"symlinks are not permitted in public releases: {relative}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

    for verifier in ("verify-no-secrets.py", "verify-public-privacy.py"):
        completed = subprocess.run(
            [sys.executable, str(destination / "scripts" / verifier), "--root", str(destination)],
            check=False,
        )
        if completed.returncode:
            return completed.returncode

    print(f"Public release exported {len(selected)} tracked files to {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
