"""Deterministic, prompt-safe voice mode configuration and commands."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
import re


class VoiceMode(StrEnum):
    ASSISTANT = "assistant"
    TRANSLATION = "translation"
    PRIVATE = "private"


class ModeCommandError(ValueError):
    """An utterance looked like a mode command but was not valid."""


@dataclass(frozen=True, slots=True)
class ModeCommand:
    mode: VoiceMode
    source_language: str | None = None
    target_language: str | None = None


@dataclass(slots=True)
class VoiceModeConfig:
    mode: VoiceMode = VoiceMode.ASSISTANT
    source_language: str | None = None
    target_language: str | None = None

    def apply(self, command: ModeCommand) -> str:
        self.mode = command.mode
        self.source_language = command.source_language
        self.target_language = command.target_language
        if command.mode == VoiceMode.TRANSLATION:
            target = command.target_language or "English"
            source = command.source_language or "auto-detect"
            return f"Translation mode on: {source} to {target}."
        if command.mode == VoiceMode.PRIVATE:
            return "Private mode on. This session will not retain transcript content."
        return "Ask mode on."

    def effective_tool_profile(self, requested: str) -> str:
        return "none" if self.mode == VoiceMode.TRANSLATION else requested

    def effective_stt_model(self, fast_model: str, multilingual_model: str | None) -> str:
        if self.mode == VoiceMode.TRANSLATION and multilingual_model:
            return multilingual_model
        return fast_model

    def instructions(self, base: str) -> str:
        if self.mode != VoiceMode.TRANSLATION:
            return base
        source = self.source_language or "the automatically detected language"
        target = self.target_language or "English"
        return (
            "You are a private real-time translator. "
            f"Translate faithfully from {source} to {target}. "
            "Return only the concise translation. Preserve names, numbers, "
            "technical terms, and uncertainty. Never browse or call tools."
        )


_LANGUAGE = re.compile(r"^[A-Za-z]{2,20}(?:[ -][A-Za-z]{2,20}){0,2}$")
_TRAILING_PUNCTUATION = re.compile(r"[.!?]+$")
_WAKE_PREFIX = re.compile(r"^hey[ ,]+gauss[ ,]+", re.IGNORECASE)


def validate_language(value: object, *, required: bool = False) -> str | None:
    if value is None or not str(value).strip():
        if required:
            raise ModeCommandError("target language is required")
        return None
    language = " ".join(str(value).strip().split())
    if not _LANGUAGE.fullmatch(language):
        raise ModeCommandError("language contains unsupported characters")
    return language


def parse_mode_command(utterance: str) -> ModeCommand | None:
    if "\n" in utterance or "\r" in utterance:
        probe = _WAKE_PREFIX.sub("", " ".join(utterance.strip().split())).lower()
        if probe.startswith("activate") or probe.startswith("translate"):
            raise ModeCommandError("mode commands must be a single utterance")
    normalized = " ".join(utterance.strip().split())
    normalized = _TRAILING_PUNCTUATION.sub("", normalized).strip()
    normalized = _WAKE_PREFIX.sub("", normalized).strip()
    lowered = normalized.lower()

    if lowered in {"activate ask", "activate ask mode", "activate assistant", "activate assistant mode"}:
        return ModeCommand(VoiceMode.ASSISTANT)
    if lowered in {"activate translation", "activate translation mode"}:
        return ModeCommand(VoiceMode.TRANSLATION, target_language="English")
    if lowered in {"activate private", "activate private mode"}:
        return ModeCommand(VoiceMode.PRIVATE)

    match = re.fullmatch(r"translate (.+?) to (.+)", normalized, re.IGNORECASE)
    if match:
        return ModeCommand(
            VoiceMode.TRANSLATION,
            source_language=validate_language(match.group(1), required=True),
            target_language=validate_language(match.group(2), required=True),
        )

    if lowered in {"activate", "translate"} \
            or lowered.startswith("activate ") \
            or lowered.startswith("translate "):
        raise ModeCommandError("invalid or extended mode command")
    return None


def intercept_mode_command(config: VoiceModeConfig, utterance: str) -> str | None:
    """Apply an exact spoken mode command, or leave an ordinary utterance alone.

    Command-like but invalid utterances deliberately retain the parser's
    fail-closed ModeCommandError so callers cannot accidentally send them to an
    agent as prompt content.
    """
    command = parse_mode_command(utterance)
    return None if command is None else config.apply(command)


def configure_mode(
    mode: object,
    source_language: object = None,
    target_language: object = None,
) -> VoiceModeConfig:
    try:
        selected = VoiceMode(str(mode or VoiceMode.ASSISTANT).strip().lower())
    except ValueError as error:
        raise ModeCommandError("unsupported voice mode") from error
    if selected == VoiceMode.TRANSLATION:
        return VoiceModeConfig(
            selected,
            validate_language(source_language),
            validate_language(target_language) or "English",
        )
    if source_language is not None or target_language is not None:
        raise ModeCommandError("language fields require translation mode")
    return VoiceModeConfig(selected)
