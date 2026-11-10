#!/usr/bin/env python3
"""Manage hashed Voice Core client credentials without accepting secrets in argv."""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import tempfile


IDENTIFIER = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
DEFAULT_REGISTRY = Path.home() / ".config" / "homeblend" / "voice-core" / "clients.json"


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def read_registry(path: Path, *, allow_missing: bool = False) -> dict:
    if allow_missing and not path.exists():
        return {"schema_version": 1, "clients": []}
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"Registry cannot be read: {path}") from error
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise SystemExit("Registry schema_version must be 1")
    if not isinstance(document.get("clients"), list):
        raise SystemExit("Registry clients must be an array")
    return document


def write_registry(path: Path, document: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    payload = json.dumps(document, indent=2, sort_keys=True) + "\n"
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=path.parent, prefix=".clients-", delete=False
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(payload)
            temporary.flush()
            os.fsync(temporary.fileno())
        # The file contains one-way hashes and metadata, not bearer tokens.
        # World-readability lets the fixed unprivileged container UID read the
        # bind mount; the parent directory remains owner-only on the host.
        os.chmod(temporary_name, 0o644)
        os.replace(temporary_name, path)
    finally:
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def validate_identifier(value: str, label: str) -> str:
    if not IDENTIFIER.fullmatch(value):
        raise SystemExit(f"{label} must match {IDENTIFIER.pattern}")
    return value


def bounded_integer(minimum: int, maximum: int):
    def parse(value: str) -> int:
        try:
            parsed = int(value)
        except ValueError as error:
            raise argparse.ArgumentTypeError("must be an integer") from error
        if not minimum <= parsed <= maximum:
            raise argparse.ArgumentTypeError(f"must be from {minimum} to {maximum}")
        return parsed
    return parse


def enroll(args: argparse.Namespace) -> None:
    path = args.registry.expanduser().resolve()
    document = read_registry(path, allow_missing=True)
    client_id = validate_identifier(args.client_id, "client ID")
    credential_id = validate_identifier(
        args.credential_id
        or f"{client_id}-{now_utc():%Y%m%d}-{secrets.token_hex(2)}",
        "credential ID",
    )
    clients = document["clients"]
    if any(entry.get("credential_id") == credential_id for entry in clients):
        raise SystemExit("Credential ID already exists")
    if any(entry.get("client_id") == client_id and entry.get("enabled") for entry in clients):
        raise SystemExit("Client already has an enabled credential; revoke or rotate it first")
    token = secrets.token_urlsafe(32)
    created_at = now_utc()
    clients.append({
        "client_id": client_id,
        "credential_id": credential_id,
        "token_sha256": hashlib.sha256(token.encode("utf-8")).hexdigest(),
        "created_at": timestamp(created_at),
        "expires_at": timestamp(created_at + timedelta(days=args.expires_days)),
        "enabled": True,
        "max_connections": args.max_connections,
        "max_requests_per_minute": args.max_requests_per_minute,
        "max_session_seconds": args.max_session_seconds,
    })
    write_registry(path, document)
    print(f"Enrolled client: {client_id}")
    print(f"Credential ID: {credential_id}")
    print("\nONE-TIME CLIENT TOKEN (save directly into the iPhone Keychain):")
    print(token)
    print("\nThe registry stores only its SHA-256 hash. This token cannot be recovered later.")


def revoke(args: argparse.Namespace) -> None:
    path = args.registry.expanduser().resolve()
    document = read_registry(path)
    credential_id = validate_identifier(args.credential_id, "credential ID")
    matches = [entry for entry in document["clients"] if entry.get("credential_id") == credential_id]
    if len(matches) != 1:
        raise SystemExit("Credential ID was not found exactly once")
    matches[0]["enabled"] = False
    matches[0]["revoked_at"] = timestamp(now_utc())
    write_registry(path, document)
    print(f"Revoked credential: {credential_id}")
    print("Restart Voice Core to terminate any already-open session immediately.")


def list_clients(args: argparse.Namespace) -> None:
    document = read_registry(args.registry.expanduser().resolve())
    for entry in document["clients"]:
        state = "enabled" if entry.get("enabled") else "disabled"
        print(
            f"{entry.get('client_id')}\t{entry.get('credential_id')}\t{state}"
            f"\texpires={entry.get('expires_at') or 'never'}"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    subparsers = parser.add_subparsers(dest="command", required=True)

    enroll_parser = subparsers.add_parser("enroll", help="generate and enroll one credential")
    enroll_parser.add_argument("client_id")
    enroll_parser.add_argument("--credential-id")
    enroll_parser.add_argument("--expires-days", type=bounded_integer(1, 3650), default=365)
    enroll_parser.add_argument("--max-connections", type=bounded_integer(1, 16), default=2)
    enroll_parser.add_argument(
        "--max-requests-per-minute", type=bounded_integer(1, 600), default=30
    )
    enroll_parser.add_argument(
        "--max-session-seconds", type=bounded_integer(60, 86_400), default=3600
    )
    enroll_parser.set_defaults(handler=enroll)

    revoke_parser = subparsers.add_parser("revoke", help="disable one credential")
    revoke_parser.add_argument("credential_id")
    revoke_parser.set_defaults(handler=revoke)

    list_parser = subparsers.add_parser("list", help="list redacted client metadata")
    list_parser.set_defaults(handler=list_clients)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
