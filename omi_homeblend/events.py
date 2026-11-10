"""Strict, device-neutral JSON events for Omi/HomeBlend clients.

Version 1 intentionally carries only the minimum text and state needed by a
client.  It has no fields for audio, credentials, precise location, or speaker
biometrics.  Free-form transcript and response text is still user data and
must be handled according to the caller's privacy and retention policy.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from types import MappingProxyType
from typing import Any, Mapping


EVENT_VERSION = 1
MAX_EVENT_JSON_BYTES = 256 * 1024

TRANSCRIPT_PARTIAL = "transcript_partial"
TRANSCRIPT_FINAL = "transcript_final"
ASSISTANT_RESPONSE_PARTIAL = "assistant_response_partial"
ASSISTANT_RESPONSE_FINAL = "assistant_response_final"
MODE_CHANGED = "mode_changed"
STATUS = "status"
ERROR = "error"

EVENT_TYPES = frozenset(
    {
        TRANSCRIPT_PARTIAL,
        TRANSCRIPT_FINAL,
        ASSISTANT_RESPONSE_PARTIAL,
        ASSISTANT_RESPONSE_FINAL,
        MODE_CHANGED,
        STATUS,
        ERROR,
    }
)

_TOP_LEVEL_FIELDS = frozenset({"version", "type", "payload"})
_PAYLOAD_FIELDS = {
    TRANSCRIPT_PARTIAL: frozenset({"text"}),
    TRANSCRIPT_FINAL: frozenset({"text"}),
    ASSISTANT_RESPONSE_PARTIAL: frozenset({"text"}),
    ASSISTANT_RESPONSE_FINAL: frozenset({"text"}),
    MODE_CHANGED: frozenset({"mode"}),
    STATUS: frozenset({"status"}),
    ERROR: frozenset({"code", "message"}),
}


class EventValidationError(ValueError):
    """Raised when an event is not exactly valid for the supported version."""


def _display_fields(fields: set[Any] | frozenset[Any]) -> str:
    return ", ".join(sorted((repr(field) for field in fields)))


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EventValidationError(f"duplicate JSON field: {key!r}")
        result[key] = value
    return result


def _reject_non_finite_number(value: str) -> None:
    raise EventValidationError(f"non-finite JSON number is not allowed: {value}")


def _validate_payload(event_type: str, payload: Any) -> dict[str, str]:
    if not isinstance(payload, dict):
        raise EventValidationError("payload must be a JSON object")

    expected = _PAYLOAD_FIELDS[event_type]
    actual = frozenset(payload)
    if actual != expected:
        missing = expected - actual
        extra = actual - expected
        details = []
        if missing:
            details.append(f"missing fields: {_display_fields(missing)}")
        if extra:
            details.append(f"unexpected fields: {_display_fields(extra)}")
        raise EventValidationError("invalid payload (" + "; ".join(details) + ")")

    validated: dict[str, str] = {}
    for field in expected:
        value = payload[field]
        if not isinstance(value, str):
            raise EventValidationError(f"payload field {field!r} must be a string")
        validated[field] = value
    return validated


@dataclass(frozen=True, slots=True)
class Event:
    """A validated version-1 event.

    ``payload`` is copied into a read-only mapping so validation cannot be
    invalidated later by mutating the caller's dictionary.
    """

    type: str
    payload: Mapping[str, str]
    version: int = EVENT_VERSION

    def __post_init__(self) -> None:
        if type(self.version) is not int or self.version != EVENT_VERSION:
            raise EventValidationError(f"unsupported event version: {self.version!r}")
        if not isinstance(self.type, str) or self.type not in EVENT_TYPES:
            raise EventValidationError(f"unknown event type: {self.type!r}")
        validated = _validate_payload(self.type, self.payload)
        object.__setattr__(self, "payload", MappingProxyType(validated))

    def to_dict(self) -> dict[str, Any]:
        """Return the exact wire representation as a new dictionary."""

        return {
            "version": self.version,
            "type": self.type,
            "payload": dict(self.payload),
        }

    def to_json(self) -> str:
        """Serialize this event to compact UTF-8-compatible JSON text."""

        return json.dumps(
            self.to_dict(),
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
        )


def event_from_dict(value: Any) -> Event:
    """Validate a decoded JSON value and return an immutable :class:`Event`."""

    if not isinstance(value, dict):
        raise EventValidationError("event must be a JSON object")
    actual = frozenset(value)
    if actual != _TOP_LEVEL_FIELDS:
        missing = _TOP_LEVEL_FIELDS - actual
        extra = actual - _TOP_LEVEL_FIELDS
        details = []
        if missing:
            details.append(f"missing fields: {_display_fields(missing)}")
        if extra:
            details.append(f"unexpected fields: {_display_fields(extra)}")
        raise EventValidationError("invalid event (" + "; ".join(details) + ")")
    return Event(
        version=value["version"],
        type=value["type"],
        payload=value["payload"],
    )


def parse_event(raw_json: str) -> Event:
    """Parse one strict version-1 JSON event.

    Bytes are deliberately not accepted: transports must decode UTF-8
    explicitly and decide how decoding failures are handled.
    """

    if not isinstance(raw_json, str):
        raise EventValidationError("event JSON must be text")
    try:
        encoded_size = len(raw_json.encode("utf-8"))
    except UnicodeEncodeError as exc:
        raise EventValidationError("event JSON is not valid UTF-8 text") from exc
    if encoded_size > MAX_EVENT_JSON_BYTES:
        raise EventValidationError("event JSON exceeds the size limit")
    try:
        decoded = json.loads(
            raw_json,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_non_finite_number,
        )
    except EventValidationError:
        raise
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        raise EventValidationError("invalid event JSON") from exc
    return event_from_dict(decoded)
