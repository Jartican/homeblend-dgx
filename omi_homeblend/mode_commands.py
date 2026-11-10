"""Deterministic parsing for explicit HomeBlend voice-mode commands.

This module recognizes interaction commands only. A successful parse never
constitutes authentication or authorization for an agent tool.
"""

from __future__ import annotations

import re
from dataclasses import dataclass


_WAKE_PREFIX = r"(?:hey[ ,]+gauss[,:]?\s+)?"
_MODE_ALIASES = {
    "ask": "ask",
    "ask mode": "ask",
    "translation": "translate",
    "translation mode": "translate",
    "translate": "translate",
    "translate mode": "translate",
    "remember": "remember",
    "remember mode": "remember",
    "transcript only": "transcript_only",
    "transcript-only": "transcript_only",
    "transcript only mode": "transcript_only",
    "transcript-only mode": "transcript_only",
    "private": "private",
    "private mode": "private",
}
_LANGUAGE = r"[a-z][a-z -]{0,39}"
_SET_MODE_RE = re.compile(
    rf"^{_WAKE_PREFIX}(?:activate|enter|switch to|turn on)\s+"
    rf"(?P<label>{'|'.join(map(re.escape, sorted(_MODE_ALIASES, key=len, reverse=True)))})"
    rf"(?:\s+to\s+(?P<target>{_LANGUAGE}))?[.!?]?$",
    re.IGNORECASE,
)
_TRANSLATE_PAIR_RE = re.compile(
    rf"^{_WAKE_PREFIX}translate\s+(?P<source>{_LANGUAGE})\s+to\s+"
    rf"(?P<target>{_LANGUAGE})[.!?]?$",
    re.IGNORECASE,
)
_STOP_RE = re.compile(
    rf"^{_WAKE_PREFIX}stop\s+listening[.!?]?$",
    re.IGNORECASE,
)


@dataclass(frozen=True, slots=True)
class ModeCommand:
    """A recognized interaction command, never an authorization decision."""

    action: str
    mode: str | None = None
    source_language: str | None = None
    target_language: str | None = None


def _language(value: str | None) -> str | None:
    if value is None:
        return None
    return " ".join(value.lower().split())


def parse_mode_command(transcript: str) -> ModeCommand | None:
    """Return an explicit mode command or ``None`` for ordinary speech.

    Matching is deliberately anchored to the complete transcript. This keeps
    quoted examples, embedded phrases, and commands followed by extra agent
    instructions from changing state accidentally.
    """

    if not isinstance(transcript, str):
        return None
    candidate = " ".join(transcript.strip().split())
    if not candidate or len(candidate) > 160:
        return None

    if _STOP_RE.fullmatch(candidate):
        return ModeCommand(action="stop_listening")

    pair = _TRANSLATE_PAIR_RE.fullmatch(candidate)
    if pair:
        return ModeCommand(
            action="set_mode",
            mode="translate",
            source_language=_language(pair.group("source")),
            target_language=_language(pair.group("target")),
        )

    mode_match = _SET_MODE_RE.fullmatch(candidate)
    if not mode_match:
        return None
    label = " ".join(mode_match.group("label").lower().split())
    mode = _MODE_ALIASES[label]
    target = _language(mode_match.group("target"))
    if target is not None and mode != "translate":
        return None
    return ModeCommand(
        action="set_mode",
        mode=mode,
        target_language=target,
    )
