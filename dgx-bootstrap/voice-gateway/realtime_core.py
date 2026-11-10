"""Transport-neutral realtime voice session state and latency accounting."""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
from enum import StrEnum
import time
from typing import Any

from realtime_protocol import AudioFrame, AudioKind, ProtocolError


class SessionState(StrEnum):
    NEW = "new"
    ARMED = "armed"
    CAPTURING = "capturing"
    THINKING = "thinking"
    SPEAKING = "speaking"
    FOLLOW_UP = "follow_up"
    CLOSED = "closed"


class DeviceKind(StrEnum):
    BROWSER = "browser"
    PHONE = "phone"
    HALO = "halo"
    G2 = "g2"


@dataclass(frozen=True, slots=True)
class DeviceCapabilities:
    kind: DeviceKind
    microphone: bool
    speaker: bool
    display: bool
    hardware_aec: bool
    audio_activity_detection: bool
    input_sample_rate_hz: int = 16_000
    input_channels: int = 1


DEVICE_PROFILES = {
    DeviceKind.BROWSER: DeviceCapabilities(
        kind=DeviceKind.BROWSER,
        microphone=True,
        speaker=True,
        display=True,
        hardware_aec=False,
        audio_activity_detection=False,
    ),
    DeviceKind.PHONE: DeviceCapabilities(
        kind=DeviceKind.PHONE,
        microphone=True,
        speaker=True,
        display=True,
        hardware_aec=True,
        audio_activity_detection=True,
    ),
    DeviceKind.HALO: DeviceCapabilities(
        kind=DeviceKind.HALO,
        microphone=True,
        speaker=True,
        display=True,
        hardware_aec=True,
        audio_activity_detection=True,
        input_sample_rate_hz=8_000,
        input_channels=2,
    ),
    DeviceKind.G2: DeviceCapabilities(
        kind=DeviceKind.G2,
        microphone=True,
        speaker=False,
        display=True,
        hardware_aec=False,
        audio_activity_detection=False,
    ),
}


@dataclass(frozen=True, slots=True)
class LatencyTargets:
    first_partial_transcript_ms: int = 500
    commit_to_final_transcript_ms: int = 700
    commit_to_first_text_ms: int = 1_000
    commit_to_first_audio_ms: int = 1_500
    barge_in_cancel_ms: int = 250


@dataclass(slots=True)
class TurnTrace:
    turn_id: str
    milestones_ms: dict[str, int] = field(default_factory=dict)

    def mark(self, name: str, at_ms: int) -> None:
        if at_ms < 0:
            raise ValueError("milestone timestamps must be non-negative")
        self.milestones_ms.setdefault(name, at_ms)

    def duration(self, start: str, end: str) -> int | None:
        if start not in self.milestones_ms or end not in self.milestones_ms:
            return None
        return max(0, self.milestones_ms[end] - self.milestones_ms[start])

    def report(self, targets: LatencyTargets | None = None) -> dict[str, Any]:
        targets = targets or LatencyTargets()
        values = {
            "speech_to_first_partial_transcript_ms": self.duration(
                "speech_started", "first_partial_transcript"
            ),
            "commit_to_final_transcript_ms": self.duration(
                "turn_committed", "final_transcript"
            ),
            "commit_to_first_text_ms": self.duration("turn_committed", "first_text"),
            "commit_to_first_audio_ms": self.duration("turn_committed", "first_audio"),
            "barge_in_cancel_ms": self.duration("barge_in", "cancelled"),
        }
        thresholds = {
            "speech_to_first_partial_transcript_ms": targets.first_partial_transcript_ms,
            "commit_to_final_transcript_ms": targets.commit_to_final_transcript_ms,
            "commit_to_first_text_ms": targets.commit_to_first_text_ms,
            "commit_to_first_audio_ms": targets.commit_to_first_audio_ms,
            "barge_in_cancel_ms": targets.barge_in_cancel_ms,
        }
        return {
            "turn_id": self.turn_id,
            "durations": values,
            "targets": asdict(targets),
            "passes": {
                name: None if value is None else value <= thresholds[name]
                for name, value in values.items()
            },
        }


def playback_target(device: DeviceCapabilities, external_audio_available: bool = False) -> str:
    if device.kind == DeviceKind.HALO:
        return "glasses"
    if device.kind in {DeviceKind.BROWSER, DeviceKind.PHONE}:
        return "client"
    return "external_audio" if external_audio_available else "phone"


def now_ms() -> int:
    return time.monotonic_ns() // 1_000_000


class VoiceSession:
    """Strict state machine shared by phone, Halo, G2, and simulator adapters."""

    def __init__(self, session_id: str):
        if not session_id.strip():
            raise ValueError("session_id is required")
        self.session_id = session_id
        self.state = SessionState.NEW
        self.device: DeviceCapabilities | None = None
        self.turn_id: str | None = None
        self.generation = 0
        self.last_audio_sequence = -1
        self.last_audio_timestamp_ms = -1
        self.audio_bytes_received = 0
        self.trace: TurnTrace | None = None

    def snapshot(self) -> dict[str, Any]:
        return {
            "session_id": self.session_id,
            "state": self.state,
            "device": self.device.kind if self.device else None,
            "turn_id": self.turn_id,
            "generation": self.generation,
            "audio_bytes_received": self.audio_bytes_received,
        }

    def _transition(self, allowed: set[SessionState], target: SessionState) -> None:
        if self.state not in allowed:
            allowed_names = ", ".join(sorted(state.value for state in allowed))
            raise ProtocolError(
                f"cannot transition from {self.state.value} to {target.value}; expected {allowed_names}"
            )
        self.state = target

    def _new_turn(self, turn_id: str, at_ms: int) -> None:
        if not turn_id.strip():
            raise ProtocolError("turn_id is required")
        self.turn_id = turn_id
        self.generation += 1
        self.last_audio_sequence = -1
        self.last_audio_timestamp_ms = -1
        self.audio_bytes_received = 0
        self.trace = TurnTrace(turn_id)
        self.trace.mark("speech_started", at_ms)

    def handle(self, event: dict[str, Any], at_ms: int | None = None) -> dict[str, Any]:
        at_ms = now_ms() if at_ms is None else at_ms
        event_type = str(event.get("type", ""))
        if event_type == "session.start":
            self._transition({SessionState.NEW}, SessionState.ARMED)
            try:
                kind = DeviceKind(str(event["device"]))
            except (KeyError, ValueError) as error:
                self.state = SessionState.NEW
                raise ProtocolError("session.start requires a supported device") from error
            self.device = DEVICE_PROFILES[kind]
        elif event_type == "wake.detected":
            # A wake phrase is an explicit request to start a new turn whether
            # the reply window has expired (armed) or is still open
            # (follow_up). Clients may detect the next wake before sending a
            # followup timeout, so rejecting this state strands the session.
            self._transition(
                {SessionState.ARMED, SessionState.FOLLOW_UP},
                SessionState.CAPTURING,
            )
            self._new_turn(str(event.get("turn_id", "")), at_ms)
        elif event_type == "turn.start":
            self._transition({SessionState.ARMED}, SessionState.CAPTURING)
            self._new_turn(str(event.get("turn_id", "")), at_ms)
        elif event_type == "speech.started":
            self._transition({SessionState.FOLLOW_UP}, SessionState.CAPTURING)
            self._new_turn(str(event.get("turn_id", "")), at_ms)
        elif event_type == "turn.commit":
            self._transition({SessionState.CAPTURING}, SessionState.THINKING)
            if self.trace:
                self.trace.mark("turn_committed", at_ms)
        elif event_type == "turn.cancel":
            self._transition({SessionState.CAPTURING}, SessionState.ARMED)
            self.turn_id = None
            self.last_audio_sequence = -1
            self.last_audio_timestamp_ms = -1
            self.audio_bytes_received = 0
            self.trace = None
        elif event_type == "text.turn":
            self._transition(
                {SessionState.ARMED, SessionState.FOLLOW_UP},
                SessionState.THINKING,
            )
            self._new_turn(str(event.get("turn_id", "")), at_ms)
            if self.trace:
                self.trace.mark("turn_committed", at_ms)
        elif event_type == "transcript.delta":
            if self.state not in {SessionState.CAPTURING, SessionState.THINKING}:
                raise ProtocolError("transcript.delta is not valid in the current state")
            if self.trace:
                self.trace.mark(
                    "final_transcript" if bool(event.get("final", False))
                    else "first_partial_transcript",
                    at_ms,
                )
        elif event_type == "response.text.delta":
            if self.state not in {SessionState.THINKING, SessionState.SPEAKING}:
                raise ProtocolError("response.text.delta requires thinking or speaking state")
            if self.trace:
                self.trace.mark("first_text", at_ms)
        elif event_type == "response.audio.started":
            self._transition({SessionState.THINKING}, SessionState.SPEAKING)
            if self.trace:
                self.trace.mark("first_audio", at_ms)
        elif event_type == "barge_in":
            self._transition({SessionState.THINKING, SessionState.SPEAKING}, SessionState.CAPTURING)
            if self.trace:
                self.trace.mark("barge_in", at_ms)
            self.generation += 1
            self.last_audio_sequence = -1
            self.last_audio_timestamp_ms = -1
            self.audio_bytes_received = 0
        elif event_type == "response.cancelled":
            if self.state != SessionState.CAPTURING or not self.trace:
                raise ProtocolError("response.cancelled requires an active barge-in")
            self.trace.mark("cancelled", at_ms)
        elif event_type == "response.failed":
            self._transition({SessionState.THINKING, SessionState.SPEAKING}, SessionState.ARMED)
            self.turn_id = None
        elif event_type == "playback.finished":
            self._transition({SessionState.SPEAKING}, SessionState.FOLLOW_UP)
            if self.trace:
                self.trace.mark("playback_finished", at_ms)
        elif event_type == "followup.timeout":
            self._transition({SessionState.FOLLOW_UP}, SessionState.ARMED)
            self.turn_id = None
        elif event_type == "session.close":
            self.state = SessionState.CLOSED
        else:
            raise ProtocolError(f"unsupported control event: {event_type}")
        return self.snapshot()

    def accept_audio(self, frame: AudioFrame) -> dict[str, int]:
        if self.state != SessionState.CAPTURING:
            raise ProtocolError("input audio is accepted only while capturing")
        if frame.kind != AudioKind.INPUT_PCM:
            raise ProtocolError("client may send only input PCM frames")
        if frame.sequence <= self.last_audio_sequence:
            raise ProtocolError("audio sequence must increase monotonically")
        if frame.timestamp_ms < self.last_audio_timestamp_ms:
            raise ProtocolError("audio timestamps must not move backwards")
        self.last_audio_sequence = frame.sequence
        self.last_audio_timestamp_ms = frame.timestamp_ms
        self.audio_bytes_received += len(frame.payload)
        return {
            "sequence": frame.sequence,
            "bytes_received": self.audio_bytes_received,
            "generation": self.generation,
        }
