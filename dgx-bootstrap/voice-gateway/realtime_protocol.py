"""Binary audio framing and JSON control messages for Exocortex Voice v2."""
from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
import json
import struct
from typing import Any


PROTOCOL_VERSION = 1
AUDIO_MAGIC = b"EXV2"
MAX_AUDIO_FRAME_BYTES = 64 * 1024
_HEADER = struct.Struct("!4sBBHIQI")


class ProtocolError(ValueError):
    """A client supplied a malformed or unsupported realtime message."""


class AudioKind(IntEnum):
    INPUT_PCM = 1
    OUTPUT_PCM = 2


@dataclass(frozen=True, slots=True)
class AudioFrame:
    kind: AudioKind
    sequence: int
    timestamp_ms: int
    payload: bytes
    flags: int = 0


def pack_audio_frame(frame: AudioFrame) -> bytes:
    if not 0 <= frame.sequence <= 0xFFFFFFFF:
        raise ProtocolError("audio sequence is out of range")
    if not 0 <= frame.timestamp_ms <= 0xFFFFFFFFFFFFFFFF:
        raise ProtocolError("audio timestamp is out of range")
    if not 0 <= frame.flags <= 0xFFFF:
        raise ProtocolError("audio flags are out of range")
    if not frame.payload or len(frame.payload) > MAX_AUDIO_FRAME_BYTES:
        raise ProtocolError("audio payload must contain 1 to 65536 bytes")
    header = _HEADER.pack(
        AUDIO_MAGIC,
        PROTOCOL_VERSION,
        int(frame.kind),
        frame.flags,
        frame.sequence,
        frame.timestamp_ms,
        len(frame.payload),
    )
    return header + frame.payload


def unpack_audio_frame(value: bytes) -> AudioFrame:
    if len(value) < _HEADER.size:
        raise ProtocolError("audio frame is shorter than its header")
    magic, version, raw_kind, flags, sequence, timestamp_ms, payload_size = _HEADER.unpack_from(value)
    if magic != AUDIO_MAGIC:
        raise ProtocolError("audio frame magic is invalid")
    if version != PROTOCOL_VERSION:
        raise ProtocolError(f"unsupported audio protocol version: {version}")
    if payload_size == 0 or payload_size > MAX_AUDIO_FRAME_BYTES:
        raise ProtocolError("audio payload size is invalid")
    if len(value) != _HEADER.size + payload_size:
        raise ProtocolError("audio frame length does not match its header")
    try:
        kind = AudioKind(raw_kind)
    except ValueError as error:
        raise ProtocolError(f"unsupported audio frame kind: {raw_kind}") from error
    return AudioFrame(
        kind=kind,
        sequence=sequence,
        timestamp_ms=timestamp_ms,
        payload=value[_HEADER.size :],
        flags=flags,
    )


def parse_control_message(raw: str) -> dict[str, Any]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ProtocolError("control message is not valid JSON") from error
    if not isinstance(value, dict):
        raise ProtocolError("control message must be an object")
    if value.get("protocol_version") != PROTOCOL_VERSION:
        raise ProtocolError("control message protocol version is unsupported")
    event_type = value.get("type")
    if not isinstance(event_type, str) or not event_type.strip():
        raise ProtocolError("control message requires a non-empty type")
    if len(raw) > 16_384:
        raise ProtocolError("control message exceeds 16384 characters")
    return value


def control_message(event_type: str, **fields: Any) -> dict[str, Any]:
    if not event_type.strip():
        raise ProtocolError("control message requires a non-empty type")
    return {"protocol_version": PROTOCOL_VERSION, "type": event_type, **fields}
