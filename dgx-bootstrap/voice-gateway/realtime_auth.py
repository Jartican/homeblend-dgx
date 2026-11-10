"""Fail-closed application authentication for realtime voice clients."""
from __future__ import annotations

import secrets
import hashlib
import json
import re
import threading
import time
from collections import defaultdict, deque
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


MIN_TOKEN_CHARACTERS = 32
MAX_TOKEN_CHARACTERS = 256
WEBSOCKET_PROTOCOL = "homeblend.voice.v1"
WEBSOCKET_AUTH_PREFIX = "auth."
CLIENT_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
CREDENTIAL_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
DEFAULT_MAX_CONNECTIONS = 2
DEFAULT_MAX_REQUESTS_PER_MINUTE = 30
DEFAULT_MAX_SESSION_SECONDS = 3600
MAX_REGISTRY_CLIENTS = 128


class RealtimeAuthConfigurationError(RuntimeError):
    """Realtime voice authentication is missing or unsafe."""


@dataclass(frozen=True)
class RealtimeClient:
    """One independently revocable Voice Core credential."""

    client_id: str
    credential_id: str
    token_hash: bytes
    created_at: datetime
    expires_at: datetime | None
    enabled: bool
    max_connections: int
    max_requests_per_minute: int
    max_session_seconds: int


@dataclass(frozen=True)
class AuthDecision:
    authorized: bool
    reason: str
    client: RealtimeClient | None = None
    compatibility_bridge: bool = False


def _parse_timestamp(value: object, field: str, *, required: bool) -> datetime | None:
    if value is None and not required:
        return None
    if not isinstance(value, str) or not value.strip():
        raise RealtimeAuthConfigurationError(f"{field} must be an RFC 3339 timestamp")
    normalized = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise RealtimeAuthConfigurationError(f"{field} must be an RFC 3339 timestamp") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise RealtimeAuthConfigurationError(f"{field} must include a timezone")
    return parsed.astimezone(timezone.utc)


def _bounded_integer(value: object, field: str, default: int, upper: int) -> int:
    if value is None:
        return default
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= upper:
        raise RealtimeAuthConfigurationError(f"{field} must be an integer from 1 to {upper}")
    return value


def load_client_registry(path: str | Path) -> tuple[RealtimeClient, ...]:
    """Load and fully validate a small registry; partial registries are rejected."""
    registry_path = Path(path)
    try:
        raw = registry_path.read_text(encoding="utf-8")
    except OSError as error:
        raise RealtimeAuthConfigurationError("realtime client registry cannot be read") from error
    try:
        document = json.loads(raw)
    except json.JSONDecodeError as error:
        raise RealtimeAuthConfigurationError("realtime client registry is not valid JSON") from error
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise RealtimeAuthConfigurationError("realtime client registry schema_version must be 1")
    entries = document.get("clients")
    if not isinstance(entries, list) or not 1 <= len(entries) <= MAX_REGISTRY_CLIENTS:
        raise RealtimeAuthConfigurationError(
            f"realtime client registry must contain 1 to {MAX_REGISTRY_CLIENTS} clients"
        )

    clients: list[RealtimeClient] = []
    client_ids: set[str] = set()
    credential_ids: set[str] = set()
    token_hashes: set[bytes] = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise RealtimeAuthConfigurationError(f"clients[{index}] must be an object")
        client_id = entry.get("client_id")
        credential_id = entry.get("credential_id")
        if not isinstance(client_id, str) or not CLIENT_ID_PATTERN.fullmatch(client_id):
            raise RealtimeAuthConfigurationError(f"clients[{index}].client_id is invalid")
        if not isinstance(credential_id, str) or not CREDENTIAL_ID_PATTERN.fullmatch(credential_id):
            raise RealtimeAuthConfigurationError(f"clients[{index}].credential_id is invalid")
        token_hash_text = entry.get("token_sha256")
        if not isinstance(token_hash_text, str):
            raise RealtimeAuthConfigurationError(f"clients[{index}].token_sha256 is invalid")
        try:
            token_hash = bytes.fromhex(token_hash_text)
        except ValueError as error:
            raise RealtimeAuthConfigurationError(
                f"clients[{index}].token_sha256 is invalid"
            ) from error
        if len(token_hash) != hashlib.sha256().digest_size:
            raise RealtimeAuthConfigurationError(
                f"clients[{index}].token_sha256 must be a SHA-256 value"
            )
        enabled = entry.get("enabled")
        if not isinstance(enabled, bool):
            raise RealtimeAuthConfigurationError(f"clients[{index}].enabled must be boolean")
        if client_id in client_ids or credential_id in credential_ids or token_hash in token_hashes:
            raise RealtimeAuthConfigurationError("client IDs, credential IDs, and token hashes must be unique")
        client_ids.add(client_id)
        credential_ids.add(credential_id)
        token_hashes.add(token_hash)
        clients.append(RealtimeClient(
            client_id=client_id,
            credential_id=credential_id,
            token_hash=token_hash,
            created_at=_parse_timestamp(entry.get("created_at"), f"clients[{index}].created_at", required=True),
            expires_at=_parse_timestamp(entry.get("expires_at"), f"clients[{index}].expires_at", required=False),
            enabled=enabled,
            max_connections=_bounded_integer(
                entry.get("max_connections"), f"clients[{index}].max_connections",
                DEFAULT_MAX_CONNECTIONS, 16,
            ),
            max_requests_per_minute=_bounded_integer(
                entry.get("max_requests_per_minute"),
                f"clients[{index}].max_requests_per_minute",
                DEFAULT_MAX_REQUESTS_PER_MINUTE, 600,
            ),
            max_session_seconds=_bounded_integer(
                entry.get("max_session_seconds"), f"clients[{index}].max_session_seconds",
                DEFAULT_MAX_SESSION_SECONDS, 86_400,
            ),
        ))
        if clients[-1].expires_at is not None and clients[-1].expires_at <= clients[-1].created_at:
            raise RealtimeAuthConfigurationError(
                f"clients[{index}].expires_at must be later than created_at"
            )
    return tuple(clients)


def require_configured_token_hashes(value: str | None) -> tuple[bytes, ...]:
    entries = [entry.strip() for entry in (value or "").split(",") if entry.strip()]
    if not entries:
        raise RealtimeAuthConfigurationError(
            "VOICE_REALTIME_CLIENT_TOKEN_SHA256 must contain at least one token hash"
        )
    hashes: list[bytes] = []
    for entry in entries:
        try:
            decoded = bytes.fromhex(entry)
        except ValueError as error:
            raise RealtimeAuthConfigurationError("realtime client token hash is not hexadecimal") from error
        if len(decoded) != hashlib.sha256().digest_size:
            raise RealtimeAuthConfigurationError("realtime client token hashes must be SHA-256 values")
        hashes.append(decoded)
    return tuple(hashes)


def extract_bearer_token(headers: Mapping[str, str]) -> str | None:
    value = headers.get("authorization") or headers.get("Authorization")
    if not value:
        return None
    scheme, separator, token = value.partition(" ")
    if not separator or scheme.lower() != "bearer" or not token.strip():
        return None
    return token.strip()


def extract_websocket_token(headers: Mapping[str, str]) -> str | None:
    """Extract browser auth without putting a secret in the WebSocket URL."""
    raw = headers.get("sec-websocket-protocol") or headers.get("Sec-WebSocket-Protocol")
    offered = [value.strip() for value in (raw or "").split(",") if value.strip()]
    if WEBSOCKET_PROTOCOL not in offered:
        return None
    candidates = [
        value[len(WEBSOCKET_AUTH_PREFIX):]
        for value in offered
        if value.startswith(WEBSOCKET_AUTH_PREFIX)
    ]
    if len(candidates) != 1:
        return None
    token = candidates[0]
    allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    if not token or any(character not in allowed for character in token):
        return None
    return token


def selected_websocket_subprotocol(headers: Mapping[str, str]) -> str | None:
    raw = headers.get("sec-websocket-protocol") or headers.get("Sec-WebSocket-Protocol")
    offered = {value.strip() for value in (raw or "").split(",") if value.strip()}
    return WEBSOCKET_PROTOCOL if WEBSOCKET_PROTOCOL in offered else None


def authorize_client(
    headers: Mapping[str, str],
    *,
    registry_path: str = "",
    configured_hashes: str = "",
    allow_unconfigured_loopback_proxy: bool = False,
    now: datetime | None = None,
) -> AuthDecision:
    """Authenticate and identify a client without ever returning its credential."""
    supplied = extract_bearer_token(headers) or extract_websocket_token(headers)
    if registry_path.strip():
        clients = load_client_registry(registry_path)
        if supplied is None:
            if allow_unconfigured_loopback_proxy:
                return AuthDecision(True, "compatibility_bridge", compatibility_bridge=True)
            return AuthDecision(False, "missing_credential")
        if not MIN_TOKEN_CHARACTERS <= len(supplied) <= MAX_TOKEN_CHARACTERS:
            return AuthDecision(False, "malformed_credential")
        supplied_hash = hashlib.sha256(supplied.encode("utf-8")).digest()
        matched_client: RealtimeClient | None = None
        # Always compare every entry so a client's registry position does not
        # change the number of constant-time digest comparisons.
        for client in clients:
            if secrets.compare_digest(supplied_hash, client.token_hash):
                matched_client = client
        if matched_client is None:
            return AuthDecision(False, "invalid_credential")
        if not matched_client.enabled:
            return AuthDecision(False, "disabled_credential", matched_client)
        effective_now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
        if matched_client.expires_at is not None and effective_now >= matched_client.expires_at:
            return AuthDecision(False, "expired_credential", matched_client)
        return AuthDecision(True, "authorized", matched_client)

    if (configured_hashes or "").strip():
        if supplied is None:
            return AuthDecision(False, "missing_credential")
        if not MIN_TOKEN_CHARACTERS <= len(supplied) <= MAX_TOKEN_CHARACTERS:
            return AuthDecision(False, "malformed_credential")
        supplied_hash = hashlib.sha256(supplied.encode("utf-8")).digest()
        matched = False
        for expected in require_configured_token_hashes(configured_hashes):
            matched = secrets.compare_digest(supplied_hash, expected) or matched
        return AuthDecision(matched, "legacy_authorized" if matched else "invalid_credential")

    if allow_unconfigured_loopback_proxy:
        return AuthDecision(True, "compatibility_bridge", compatibility_bridge=True)
    raise RealtimeAuthConfigurationError(
        "VOICE_REALTIME_CLIENT_REGISTRY or VOICE_REALTIME_CLIENT_TOKEN_SHA256 must be configured"
    )


class ClientAccessController:
    """Small in-process connection and request limiter keyed by client ID."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._connections: dict[str, int] = defaultdict(int)
        self._requests: dict[str, deque[float]] = defaultdict(deque)

    def try_open(self, client: RealtimeClient) -> bool:
        with self._lock:
            if self._connections[client.client_id] >= client.max_connections:
                return False
            self._connections[client.client_id] += 1
            return True

    def close(self, client: RealtimeClient) -> None:
        with self._lock:
            remaining = max(0, self._connections.get(client.client_id, 0) - 1)
            if remaining:
                self._connections[client.client_id] = remaining
            else:
                self._connections.pop(client.client_id, None)

    def allow_request(self, client: RealtimeClient, *, now: float | None = None) -> bool:
        timestamp = time.monotonic() if now is None else now
        cutoff = timestamp - 60.0
        with self._lock:
            recent = self._requests[client.client_id]
            while recent and recent[0] <= cutoff:
                recent.popleft()
            if len(recent) >= client.max_requests_per_minute:
                return False
            recent.append(timestamp)
            return True


class AuthFailureMonitor:
    """Emit a rate-limited signal after repeated content-free auth failures."""

    def __init__(
        self,
        *,
        threshold: int = 5,
        window_seconds: float = 300.0,
        alert_cooldown_seconds: float = 300.0,
    ) -> None:
        if threshold < 1 or window_seconds <= 0 or alert_cooldown_seconds <= 0:
            raise ValueError("authentication alert limits must be positive")
        self.threshold = threshold
        self.window_seconds = window_seconds
        self.alert_cooldown_seconds = alert_cooldown_seconds
        self._lock = threading.Lock()
        self._failures: deque[float] = deque()
        self._last_alert: float | None = None

    def record_failure(self, *, now: float | None = None) -> int | None:
        timestamp = time.monotonic() if now is None else now
        cutoff = timestamp - self.window_seconds
        with self._lock:
            while self._failures and self._failures[0] <= cutoff:
                self._failures.popleft()
            self._failures.append(timestamp)
            if len(self._failures) < self.threshold:
                return None
            if (
                self._last_alert is not None
                and timestamp - self._last_alert < self.alert_cooldown_seconds
            ):
                return None
            self._last_alert = timestamp
            return len(self._failures)


def is_authorized(
    headers: Mapping[str, str],
    configured_hashes: str,
    *,
    allow_unconfigured_loopback_proxy: bool = False,
) -> bool:
    return authorize_client(
        headers,
        configured_hashes=configured_hashes,
        allow_unconfigured_loopback_proxy=allow_unconfigured_loopback_proxy,
    ).authorized
