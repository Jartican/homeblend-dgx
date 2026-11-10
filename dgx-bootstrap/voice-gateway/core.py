"""Pure validation and routing helpers for the private voice gateway."""
from __future__ import annotations

import json
import re
from typing import Any


MODEL_ALIASES = {
    "8b": "exocortex-chat-fast",
    "27b": "exocortex-agent-quality",
}
COMPLEXITY_MARKERS = frozenset({
    "analyze", "architecture", "debug", "diagnose", "implement",
    "migration", "refactor", "security", "tradeoff",
})
VOICE_MODES = frozenset({"personal", "conversation", "transcript"})


def validate_options(model: str, effort: int, tool_profile: str) -> tuple[str, int, str]:
    model = model.strip().lower()
    tool_profile = tool_profile.strip().lower()
    if model not in {"auto", *MODEL_ALIASES}:
        raise ValueError("model must be auto, 8b, or 27b")
    if effort not in range(1, 6):
        raise ValueError("effort must be between 1 and 5")
    if tool_profile not in {"none", "web"}:
        raise ValueError("tool_profile must be none or web")
    return model, effort, tool_profile


def select_model(text: str, requested: str = "auto", effort: int = 1) -> str:
    requested, effort, _ = validate_options(requested, effort, "none")
    if requested != "auto":
        return MODEL_ALIASES[requested]
    words = set(re.findall(r"[a-z]+", text.lower()))
    if effort >= 3 or len(text) >= 600 or words.intersection(COMPLEXITY_MARKERS):
        return MODEL_ALIASES["27b"]
    return MODEL_ALIASES["8b"]


def extract_transcript(payload: Any) -> str:
    if not isinstance(payload, dict) or not isinstance(payload.get("text"), str):
        raise ValueError("invalid transcription response")
    transcript = payload["text"].strip()
    if not transcript:
        raise ValueError("transcription was empty")
    return transcript


def extract_answer(payload: Any) -> str:
    if not isinstance(payload, dict):
        raise ValueError("invalid inference response")
    for item in payload.get("output", []):
        if not isinstance(item, dict) or item.get("type") != "message":
            continue
        for part in item.get("content", []):
            if isinstance(part, dict) and part.get("type") == "output_text":
                answer = str(part.get("text", "")).strip()
                if answer:
                    return answer
    raise ValueError("inference response contained no answer")


def security_state() -> dict[str, dict[str, Any]]:
    # Client-supplied claims are deliberately absent: v0 performs no identity check.
    state = {"enabled": False, "status": "not_evaluated", "trusted": False}
    return {"wake_word": dict(state), "voice_auth": dict(state)}


def validate_voice_mode(mode: str) -> str:
    mode = mode.strip().lower()
    if mode not in VOICE_MODES:
        raise ValueError("voice mode must be personal, conversation, or transcript")
    return mode


def authorize_speaker(
    mode: str,
    *,
    owner_verified: bool,
    session_armed_by_owner: bool = False,
    recording_consent: bool = False,
) -> dict[str, Any]:
    """Return an explicit, auditable policy decision; never infer consent."""
    mode = validate_voice_mode(mode)
    if mode == "personal":
        accepted = owner_verified
        reason = "owner_verified" if accepted else "speaker_not_verified"
    elif mode == "conversation":
        accepted = session_armed_by_owner
        reason = "owner_armed_open_conversation" if accepted else "owner_has_not_armed_session"
    else:
        accepted = session_armed_by_owner and recording_consent
        reason = "owner_armed_consented_transcript" if accepted else "explicit_consent_required"
    return {
        "mode": mode,
        "accepted": accepted,
        "reason": reason,
        "owner_verified": owner_verified,
        "session_armed_by_owner": session_armed_by_owner,
        "recording_consent": recording_consent,
    }


def parse_history(raw: str | None, max_messages: int = 20, max_characters: int = 12_000) -> list[dict[str, str]]:
    if not raw:
        return []
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ValueError("history_json must be valid JSON") from error
    if not isinstance(value, list) or len(value) > max_messages:
        raise ValueError(f"history_json must contain at most {max_messages} messages")
    result: list[dict[str, str]] = []
    total = 0
    for item in value:
        if not isinstance(item, dict) or item.get("role") not in {"user", "assistant"}:
            raise ValueError("history messages require a user or assistant role")
        content = item.get("content")
        if not isinstance(content, str) or not content.strip():
            raise ValueError("history message content must be non-empty text")
        content = content.strip()
        total += len(content)
        if total > max_characters:
            raise ValueError(f"history_json exceeds {max_characters} characters")
        result.append({"role": item["role"], "content": content})
    return result
