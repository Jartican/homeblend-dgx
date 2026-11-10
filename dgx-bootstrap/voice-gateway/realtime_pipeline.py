"""Pure helpers for bounded, in-memory realtime voice turns."""
from __future__ import annotations

from dataclasses import dataclass
from io import BytesIO
import json
import re
import wave
from typing import Any

from realtime_protocol import ProtocolError


@dataclass(frozen=True, slots=True)
class PcmFormat:
    sample_rate_hz: int
    channels: int
    sample_width_bytes: int = 2

    def __post_init__(self) -> None:
        if not 8_000 <= self.sample_rate_hz <= 48_000:
            raise ValueError("PCM sample rate must be between 8000 and 48000 Hz")
        if self.channels not in {1, 2}:
            raise ValueError("PCM must contain one or two channels")
        if self.sample_width_bytes != 2:
            raise ValueError("only signed 16-bit PCM is supported")


class PcmTurnBuffer:
    """Bound one turn of raw audio in memory and serialize it as a WAV."""

    def __init__(self, audio_format: PcmFormat, max_bytes: int):
        if max_bytes < 3_200:
            raise ValueError("max_bytes is too small for a voice turn")
        self.audio_format = audio_format
        self.max_bytes = max_bytes
        self._buffer = bytearray()

    @property
    def size(self) -> int:
        return len(self._buffer)

    @property
    def duration_ms(self) -> int:
        bytes_per_second = (
            self.audio_format.sample_rate_hz
            * self.audio_format.channels
            * self.audio_format.sample_width_bytes
        )
        return round(1000 * len(self._buffer) / bytes_per_second)

    def append(self, payload: bytes) -> None:
        frame_width = self.audio_format.channels * self.audio_format.sample_width_bytes
        if not payload or len(payload) % frame_width:
            raise ProtocolError("PCM payload is not aligned to a complete sample frame")
        if len(self._buffer) + len(payload) > self.max_bytes:
            raise ProtocolError("realtime audio exceeds the configured per-turn limit")
        self._buffer.extend(payload)

    def clear(self) -> None:
        self._buffer.clear()

    def wav_bytes(self) -> bytes:
        if not self._buffer:
            raise ProtocolError("cannot commit an empty audio turn")
        destination = BytesIO()
        with wave.open(destination, "wb") as output:
            output.setnchannels(self.audio_format.channels)
            output.setsampwidth(self.audio_format.sample_width_bytes)
            output.setframerate(self.audio_format.sample_rate_hz)
            output.writeframes(self._buffer)
        return destination.getvalue()


def decode_wav_pcm(value: bytes) -> tuple[PcmFormat, bytes]:
    """Decode a bounded uncompressed WAV returned by the private TTS service."""
    try:
        with wave.open(BytesIO(value), "rb") as source:
            audio_format = PcmFormat(
                sample_rate_hz=source.getframerate(),
                channels=source.getnchannels(),
                sample_width_bytes=source.getsampwidth(),
            )
            if source.getcomptype() != "NONE":
                raise ValueError("compressed WAV output is unsupported")
            payload = source.readframes(source.getnframes())
    except (EOFError, wave.Error) as error:
        raise ValueError("private TTS returned an invalid WAV") from error
    if not payload:
        raise ValueError("private TTS returned an empty WAV")
    return audio_format, payload


class PhraseBuffer:
    """Turn model deltas into independently speakable early chunks."""

    def __init__(self, first_limit: int = 60, later_limit: int = 180):
        if not 20 <= first_limit <= later_limit:
            raise ValueError("invalid phrase limits")
        self.first_limit = first_limit
        self.later_limit = later_limit
        self._limit = first_limit
        self._text = ""

    @staticmethod
    def _boundary(text: str, limit: int) -> int | None:
        sentence = re.search(r"[.!?](?:[\"')\]]?)(?:\s+|$)", text)
        if sentence and sentence.end() >= 20:
            return sentence.end()
        if len(text) < limit:
            return None
        space = text.rfind(" ", 20, limit + 1)
        return space + 1 if space >= 20 else limit

    def feed(self, delta: str) -> list[str]:
        self._text += delta
        ready: list[str] = []
        while (boundary := self._boundary(self._text, self._limit)) is not None:
            phrase = self._text[:boundary].strip()
            self._text = self._text[boundary:].lstrip()
            if phrase:
                ready.append(phrase)
                self._limit = self.later_limit
        return ready

    def flush(self) -> list[str]:
        phrase = self._text.strip()
        self._text = ""
        return [phrase] if phrase else []


def parse_sse_data_line(line: str) -> dict[str, Any] | None:
    line = line.strip()
    if not line or line.startswith(":") or not line.startswith("data:"):
        return None
    value = line[5:].strip()
    if value == "[DONE]":
        return None
    try:
        event = json.loads(value)
    except json.JSONDecodeError as error:
        raise ValueError("private inference returned invalid SSE JSON") from error
    if not isinstance(event, dict):
        raise ValueError("private inference SSE event must be an object")
    return event


class BoundedConversation:
    """Ephemeral user/assistant history with role and size limits."""

    def __init__(self, max_messages: int = 12, max_characters: int = 20_000):
        self.max_messages = max_messages
        self.max_characters = max_characters
        self._messages: list[dict[str, str]] = []

    def snapshot(self) -> list[dict[str, str]]:
        return [dict(message) for message in self._messages]

    def append_turn(self, user: str, assistant: str) -> None:
        self._messages.extend((
            {"role": "user", "content": user.strip()},
            {"role": "assistant", "content": assistant.strip()},
        ))
        while len(self._messages) > self.max_messages:
            self._messages.pop(0)
        while sum(len(item["content"]) for item in self._messages) > self.max_characters:
            self._messages.pop(0)
