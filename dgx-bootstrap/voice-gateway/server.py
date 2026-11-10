"""In-memory STT -> HomeBlend -> TTS facade for private voice clients."""
from __future__ import annotations

import base64
import asyncio
from array import array
from collections import OrderedDict
from datetime import datetime, timezone
import io
import json
import math
import os
import re
import secrets
import sys
import time
from typing import Annotated

import httpx
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from starlette.datastructures import Headers

from core import extract_answer, parse_history, security_state, select_model, validate_options
from realtime_adapters import adapter_manifest
from realtime_auth import (
    AuthFailureMonitor,
    ClientAccessController,
    RealtimeAuthConfigurationError,
    authorize_client,
    load_client_registry,
    selected_websocket_subprotocol,
)
from realtime_core import DeviceKind, VoiceSession
from realtime_modes import VoiceModeConfig, configure_mode, intercept_mode_command
from realtime_pipeline import BoundedConversation, PcmFormat, PcmTurnBuffer, PhraseBuffer, parse_sse_data_line
from realtime_protocol import AudioFrame, AudioKind, ProtocolError, control_message, pack_audio_frame, parse_control_message, unpack_audio_frame
from realtime_runtime import TurnCoordinator


SPEACHES_URL = os.environ.get("VOICE_SPEACHES_URL", "http://127.0.0.1:8002/v1").rstrip("/")
HOMEBLEND_URL = os.environ.get("VOICE_HOMEBLEND_URL", "http://127.0.0.1:8770/v1").rstrip("/")
SPEAKER_URL = os.environ.get("VOICE_SPEAKER_URL", "http://127.0.0.1:8792/v1/speaker").rstrip("/")
WAKE_URL = os.environ.get("VOICE_NEURAL_WAKE_URL", "").rstrip("/")
DENOISER_URL = os.environ.get("VOICE_DENOISER_URL", "").rstrip("/")
DIARIZATION_URL = os.environ.get("VOICE_DIARIZATION_URL", "").rstrip("/")
STT_MODEL = os.environ.get("SPEACHES_STT_MODEL", "Systran/faster-whisper-small")
FAST_STT_MODEL = os.environ.get("SPEACHES_FAST_STT_MODEL", "Systran/faster-whisper-tiny.en")
MULTILINGUAL_STT_MODEL = os.environ.get("SPEACHES_MULTILINGUAL_STT_MODEL", "").strip()
WAKE_STT_MODEL = os.environ.get("SPEACHES_WAKE_STT_MODEL", "Systran/faster-whisper-tiny.en")
TTS_MODEL = os.environ.get("SPEACHES_TTS_MODEL", "speaches-ai/Kokoro-82M-v1.0-ONNX")
DEFAULT_VOICE = os.environ.get("SPEACHES_TTS_VOICE", "af_heart")
MAX_AUDIO_BYTES = int(os.environ.get("VOICE_MAX_AUDIO_BYTES", "20000000"))
MAX_DIARIZATION_AUDIO_BYTES = int(os.environ.get("DIARIZATION_MAX_AUDIO_BYTES", "100000000"))
MAX_DIARIZATION_SEGMENTS = min(
    max(int(os.environ.get("VOICE_MAX_DIARIZATION_SEGMENTS", "80")), 2), 200
)
MAX_TEXT_CHARACTERS = int(os.environ.get("VOICE_MAX_TEXT_CHARACTERS", "20000"))
MAX_TTS_CHARACTERS = int(os.environ.get("VOICE_MAX_TTS_CHARACTERS", "4000"))
TIMEOUT_SECONDS = float(os.environ.get("VOICE_UPSTREAM_TIMEOUT_SECONDS", "300"))
SYSTEM_INSTRUCTIONS = os.environ.get(
    "VOICE_SYSTEM_INSTRUCTIONS",
    "You are a private assistant speaking through a very small glasses display. "
    "Put the direct answer first. Default to one or two short sentences and no more "
    "than 240 characters. Name a source briefly when useful, but omit long URLs. "
    "Give more detail only when the user explicitly asks for it.",
)
WAKE_WORD = os.environ.get("VOICE_WAKE_WORD", "Gauss").strip() or "Gauss"
WAKE_ALIASES = tuple(
    dict.fromkeys(
        alias.strip().lower()
        for alias in os.environ.get("VOICE_WAKE_ALIASES", "gauss,gaus,goss,gouse,gauze").split(",")
        if alias.strip()
    )
)
WAKE_PROMPT = os.environ.get(
    "VOICE_WAKE_PROMPT", f"The speaker may say the wake word {WAKE_WORD}."
).strip()[:500]
WAKE_HOTWORDS = os.environ.get("VOICE_WAKE_HOTWORDS", WAKE_WORD).strip()[:500]
WAKE_VAD_FILTER = os.environ.get("VOICE_WAKE_VAD_FILTER", "true").strip().lower() not in {
    "0", "false", "no", "off",
}
WAKE_ASR_FALLBACK = os.environ.get(
    "VOICE_WAKE_ASR_FALLBACK", "true"
).strip().lower() in {"1", "true", "yes", "on"}
WAKE_ASR_RMS_THRESHOLD = min(max(float(os.environ.get(
    "VOICE_WAKE_ASR_RMS_THRESHOLD", "0.008"
)), 0.001), 0.1)
# Inline wake commands need enough context for both the phrase and a short
# request. Clamp stale one-second deployments upward; native continuous/ring-
# buffer clients can later replace this foreground-browser compromise.
WAKE_CLIP_MS = min(max(int(os.environ.get("VOICE_WAKE_CLIP_MS", "2500")), 2500), 10_000)
WAKE_COMMAND_MAX_MS = min(max(int(os.environ.get("VOICE_WAKE_COMMAND_MAX_MS", "10000")), 3000), 30_000)
WAKE_SILENCE_MS = min(max(int(os.environ.get("VOICE_WAKE_SILENCE_MS", "1200")), 500), 5000)
CONVERSATION_REPLY_WINDOW_MS = min(
    max(int(os.environ.get("VOICE_CONVERSATION_REPLY_WINDOW_MS", "8000")), 3000), 30_000
)
CONVERSATION_REARM_DELAY_MS = min(
    max(int(os.environ.get("VOICE_CONVERSATION_REARM_DELAY_MS", "350")), 100), 2000
)
STREAM_START_TIMEOUT_MS = min(
    max(int(os.environ.get("VOICE_STREAM_START_TIMEOUT_MS", "20000")), 4000), 60_000
)
TTS_STREAM_CHUNK_CHARACTERS = min(
    max(int(os.environ.get("VOICE_TTS_STREAM_CHUNK_CHARACTERS", "180")), 80), 500
)
TTS_FIRST_CHUNK_CHARACTERS = min(
    max(int(os.environ.get("VOICE_TTS_FIRST_CHUNK_CHARACTERS", "60")), 40),
    TTS_STREAM_CHUNK_CHARACTERS,
)
SPEECH_JOB_TTL_SECONDS = min(max(int(os.environ.get("VOICE_SPEECH_JOB_TTL_SECONDS", "60")), 10), 300)
MAX_SPEECH_JOBS = min(max(int(os.environ.get("VOICE_MAX_SPEECH_JOBS", "64")), 4), 256)
REALTIME_ENABLED = os.environ.get("VOICE_REALTIME_ENABLED", "false").strip().lower() in {
    "1", "true", "yes", "on",
}
REALTIME_CLIENT_TOKEN_SHA256 = os.environ.get("VOICE_REALTIME_CLIENT_TOKEN_SHA256", "")
REALTIME_CLIENT_REGISTRY = os.environ.get("VOICE_REALTIME_CLIENT_REGISTRY", "").strip()
REALTIME_ALLOW_TAILNET_UNAUTHENTICATED = os.environ.get(
    "VOICE_REALTIME_ALLOW_TAILNET_UNAUTHENTICATED", "false"
).strip().lower() in {"1", "true", "yes", "on"}
AUDIT_LOG_PATH = os.environ.get("VOICE_AUDIT_LOG", "").strip()
REALTIME_MAX_SESSION_SECONDS = min(max(int(os.environ.get(
    "VOICE_REALTIME_MAX_SESSION_SECONDS", "3600"
)), 60), 86_400)

# Values live only between the POST that authorizes synthesis and the first GET
# from the native audio player. Tokens are random, single-use, and short-lived.
speech_jobs: OrderedDict[str, tuple[float, str, str | None]] = OrderedDict()
client_access = ClientAccessController()
auth_failure_monitor = AuthFailureMonitor()
_audit_sink_error = False

app = FastAPI(title="Exocortex private voice gateway", docs_url=None, redoc_url=None)
app.mount(
    "/homeblend",
    StaticFiles(directory="/app/homeblend-client", html=True, check_dir=False),
    name="homeblend-client",
)


@app.middleware("http")
async def no_store_homeblend_client(request: Request, call_next):
    response = await call_next(request)
    if request.url.path.startswith("/homeblend"):
        response.headers["Cache-Control"] = "no-store, max-age=0"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
    return response


def protected_http_route(path: str) -> bool:
    return path.startswith("/v1/voice/")


def audit_http_route(path: str) -> str:
    if path.startswith("/v1/voice/speech-stream/"):
        return "/v1/voice/speech-stream/{job_id}"
    return path


@app.middleware("http")
async def require_voice_http_authentication(request: Request, call_next):
    """Protect every operational HTTP voice route with the client registry."""
    if not protected_http_route(request.url.path):
        return await call_next(request)
    request_id = secrets.token_hex(16)
    route = audit_http_route(request.url.path)
    try:
        auth = authorize_client(
            request.headers,
            registry_path=REALTIME_CLIENT_REGISTRY,
            configured_hashes=REALTIME_CLIENT_TOKEN_SHA256,
            allow_unconfigured_loopback_proxy=REALTIME_ALLOW_TAILNET_UNAUTHENTICATED,
        )
    except RealtimeAuthConfigurationError:
        write_voice_audit({
            "event": "voice_http_authentication",
            "request_id": request_id,
            "method": request.method,
            "route": route,
            "decision": "error",
            "reason": "authentication_not_configured",
        })
        return JSONResponse(
            {"detail": "voice authentication is not configured"},
            status_code=503,
            headers={"Cache-Control": "no-store"},
        )
    identity = {
        "client_id": auth.client.client_id if auth.client else None,
        "credential_id": auth.client.credential_id if auth.client else None,
    }
    audit_written = write_voice_audit({
        "event": "voice_http_authentication",
        "request_id": request_id,
        "method": request.method,
        "route": route,
        "decision": "allowed" if auth.authorized else "denied",
        "reason": auth.reason,
        **identity,
    })
    if (
        auth.authorized
        and REALTIME_CLIENT_REGISTRY
        and not REALTIME_ALLOW_TAILNET_UNAUTHENTICATED
        and not audit_written
    ):
        return JSONResponse(
            {"detail": "voice audit sink unavailable"},
            status_code=503,
            headers={"Cache-Control": "no-store"},
        )
    if not auth.authorized:
        failure_count = auth_failure_monitor.record_failure()
        if failure_count is not None:
            write_voice_audit({
                "event": "voice_authentication_alert",
                "request_id": request_id,
                "decision": "alert",
                "reason": "repeated_authentication_failures",
                "failure_count": failure_count,
                "window_seconds": round(auth_failure_monitor.window_seconds),
            })
        return JSONResponse(
            {"detail": "voice authentication required"},
            status_code=401,
            headers={"WWW-Authenticate": "Bearer", "Cache-Control": "no-store"},
        )
    if (
        auth.client is not None
        and request.method == "POST"
        and not client_access.allow_request(auth.client)
    ):
        write_voice_audit({
            "event": "voice_http_rate_limit",
            "request_id": request_id,
            "method": request.method,
            "route": route,
            "decision": "denied",
            "reason": "request_limit",
            **identity,
        })
        return JSONResponse(
            {"detail": "voice request limit reached"},
            status_code=429,
            headers={"Cache-Control": "no-store"},
        )
    request.state.voice_client_id = auth.client.client_id if auth.client else None
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    return response


def elapsed_ms(start: float) -> int:
    return round((time.perf_counter() - start) * 1000)


def pcm_float32_rms(value: bytes) -> float:
    if not value or len(value) % 4:
        return 0.0
    samples = array("f")
    samples.frombytes(value)
    if sys.byteorder != "little":
        samples.byteswap()
    return math.sqrt(math.fsum(sample * sample for sample in samples) / len(samples))


def wake_transcript_matches(value: str) -> bool:
    aliases = "|".join(re.escape(alias) for alias in WAKE_ALIASES)
    normalized = " ".join(value.strip().lower().split())
    return bool(re.match(rf"^(?:hey[\s,]+)?(?:{aliases})(?:\b|$)", normalized))


def validate_client_source(value: object) -> str:
    source = "unspecified" if value is None else str(value).strip().lower()
    if not re.fullmatch(r"[a-z0-9][a-z0-9_.-]{0,63}", source):
        raise ProtocolError("source contains unsupported characters")
    return source


def audit_sink_state() -> dict:
    if not AUDIT_LOG_PATH:
        return {"status": "disabled", "required": bool(REALTIME_CLIENT_REGISTRY)}
    parent = os.path.dirname(AUDIT_LOG_PATH) or "."
    writable = os.path.isdir(parent) and os.access(parent, os.W_OK)
    if os.path.exists(AUDIT_LOG_PATH):
        writable = writable and os.access(AUDIT_LOG_PATH, os.W_OK)
    if _audit_sink_error or not writable:
        return {"status": "error", "required": bool(REALTIME_CLIENT_REGISTRY)}
    return {"status": "ready", "required": bool(REALTIME_CLIENT_REGISTRY)}


def write_voice_audit(event: dict) -> bool:
    """Append one content-free audit record and report sink availability."""
    global _audit_sink_error
    if not AUDIT_LOG_PATH:
        return False
    record = {
        "schema_version": 1,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "event": "voice_turn",
        "content_persisted": False,
        **event,
    }
    try:
        with open(AUDIT_LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
        _audit_sink_error = False
        return True
    except OSError:
        _audit_sink_error = True
        print("voice audit sink write failed", file=sys.stderr, flush=True)
        return False


def application_auth_state() -> dict:
    audit = audit_sink_state()
    if REALTIME_CLIENT_REGISTRY:
        try:
            clients = load_client_registry(REALTIME_CLIENT_REGISTRY)
        except RealtimeAuthConfigurationError:
            return {
                "mode": "registry",
                "registry_status": "invalid",
                "compatibility_bridge": REALTIME_ALLOW_TAILNET_UNAUTHENTICATED,
                "production_ready": False,
                "http_routes_protected": True,
                "audit_sink": audit,
            }
        return {
            "mode": "registry",
            "registry_status": "valid",
            "enabled_clients": sum(client.enabled for client in clients),
            "compatibility_bridge": REALTIME_ALLOW_TAILNET_UNAUTHENTICATED,
            "production_ready": (
                not REALTIME_ALLOW_TAILNET_UNAUTHENTICATED
                and audit["status"] == "ready"
            ),
            "http_routes_protected": True,
            "audit_sink": audit,
        }
    if REALTIME_CLIENT_TOKEN_SHA256.strip():
        return {
            "mode": "legacy_hashes",
            "registry_status": "absent",
            "compatibility_bridge": False,
            "production_ready": False,
            "http_routes_protected": True,
            "audit_sink": audit,
        }
    if REALTIME_ALLOW_TAILNET_UNAUTHENTICATED:
        return {
            "mode": "compatibility_bridge",
            "registry_status": "absent",
            "compatibility_bridge": True,
            "production_ready": False,
            "http_routes_protected": True,
            "audit_sink": audit,
        }
    return {
        "mode": "not_enrolled",
        "registry_status": "absent",
        "compatibility_bridge": False,
        "production_ready": False,
        "http_routes_protected": True,
        "audit_sink": audit,
    }


def validate_approximate_location(value: object) -> dict[str, float] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ProtocolError("location must be an object")
    try:
        latitude = round(float(value["latitude"]), 2)
        longitude = round(float(value["longitude"]), 2)
    except (KeyError, TypeError, ValueError) as error:
        raise ProtocolError("location requires numeric latitude and longitude") from error
    if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
        raise ProtocolError("location coordinates are out of range")
    return {"latitude": latitude, "longitude": longitude}


def split_speech_text(text: str) -> list[str]:
    """Make independently synthesized, sentence-like chunks for early playback."""
    sentences = re.split(r"(?<=[.!?])\s+|\n+", text.strip())
    chunks: list[str] = []
    for sentence in filter(None, (part.strip() for part in sentences)):
        limit = TTS_FIRST_CHUNK_CHARACTERS if not chunks else TTS_STREAM_CHUNK_CHARACTERS
        while len(sentence) > limit:
            boundary = sentence.rfind(" ", 0, limit + 1)
            boundary = boundary if boundary >= 40 else limit
            chunks.append(sentence[:boundary].strip())
            sentence = sentence[boundary:].strip()
            limit = TTS_STREAM_CHUNK_CHARACTERS
        if sentence:
            chunks.append(sentence)
    return chunks or [text.strip()]


async def post(client: httpx.AsyncClient, url: str, **kwargs) -> httpx.Response:
    try:
        response = await client.post(url, **kwargs)
        response.raise_for_status()
        return response
    except (httpx.ConnectError, httpx.TimeoutException) as error:
        raise HTTPException(status_code=503, detail="private voice dependency unavailable") from error
    except httpx.HTTPStatusError as error:
        raise HTTPException(status_code=502, detail="private voice dependency failed") from error


async def denoise_audio_bytes(client: httpx.AsyncClient, audio_bytes: bytes, content_type: str) -> bytes:
    if not DENOISER_URL:
        return audio_bytes
    response = await post(
        client,
        DENOISER_URL + "/v1/audio/enhance",
        content=audio_bytes,
        headers={"Content-Type": content_type},
    )
    if not response.content:
        raise HTTPException(status_code=502, detail="private denoiser returned empty audio")
    return response.content


async def transcribe_upload(
    client: httpx.AsyncClient,
    audio: UploadFile,
    *,
    allow_empty: bool = False,
    wake_detection: bool = False,
    model_override: str | None = None,
    use_server_denoiser: bool = True,
) -> str:
    audio_bytes = await audio.read(MAX_AUDIO_BYTES + 1)
    await audio.close()
    if len(audio_bytes) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="audio exceeds configured size limit")
    if not audio_bytes:
        raise HTTPException(status_code=400, detail="audio was empty")
    content_type = audio.content_type or "application/octet-stream"
    if use_server_denoiser:
        audio_bytes = await denoise_audio_bytes(client, audio_bytes, content_type)
        content_type = "audio/wav" if DENOISER_URL else content_type
    transcription_options = {
        "model": WAKE_STT_MODEL if wake_detection else (model_override or STT_MODEL)
    }
    if wake_detection:
        if WAKE_PROMPT:
            transcription_options["prompt"] = WAKE_PROMPT
        if WAKE_HOTWORDS:
            transcription_options["hotwords"] = WAKE_HOTWORDS
        transcription_options["vad_filter"] = str(WAKE_VAD_FILTER).lower()
    response = await post(
        client,
        SPEACHES_URL + "/audio/transcriptions",
        files={"file": (audio.filename or "voice-input", audio_bytes, content_type)},
        data=transcription_options,
    )
    try:
        payload = response.json()
    except (ValueError, TypeError) as error:
        raise HTTPException(status_code=502, detail="private transcription returned an invalid response") from error
    if not isinstance(payload, dict) or not isinstance(payload.get("text"), str):
        raise HTTPException(status_code=502, detail="private transcription returned an invalid response")
    transcript = payload["text"].strip()
    if not transcript and not allow_empty:
        raise HTTPException(status_code=422, detail="no speech was detected")
    return transcript


async def pcm_for_wake(audio_bytes: bytes) -> bytes:
    """Decode browser audio to bounded 16 kHz float32 PCM without persistence."""
    process = await asyncio.create_subprocess_exec(
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", "pipe:0",
        "-ac", "1", "-ar", "16000", "-f", "f32le", "pipe:1",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        output, error = await asyncio.wait_for(process.communicate(audio_bytes), timeout=8)
    except TimeoutError as exc:
        process.kill()
        await process.wait()
        raise HTTPException(status_code=422, detail="wake audio decode timed out") from exc
    if process.returncode or not output:
        raise HTTPException(status_code=422, detail="wake audio could not be decoded")
    if len(output) > 1_000_000:
        raise HTTPException(status_code=413, detail="decoded wake audio exceeds size limit")
    return output


async def slice_audio(audio_bytes: bytes, start_seconds: float, end_seconds: float) -> bytes:
    """Extract one bounded mono WAV segment through pipes only."""
    process = await asyncio.create_subprocess_exec(
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", "pipe:0",
        "-ss", f"{start_seconds:.3f}", "-to", f"{end_seconds:.3f}",
        "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "-f", "wav", "pipe:1",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        output, _ = await asyncio.wait_for(process.communicate(audio_bytes), timeout=30)
    except TimeoutError as exc:
        process.kill()
        await process.wait()
        raise HTTPException(status_code=422, detail="conversation audio slicing timed out") from exc
    if process.returncode or not output:
        raise HTTPException(status_code=422, detail="conversation segment could not be decoded")
    return output


async def request_diarization(
    client: httpx.AsyncClient,
    content: bytes,
    filename: str,
    content_type: str,
) -> dict:
    response = await post(
        client,
        DIARIZATION_URL + "/v1/diarize",
        files={"audio": (filename, content, content_type)},
        data={"consent": "true"},
    )
    try:
        result = response.json()
    except ValueError as exc:
        raise HTTPException(status_code=502, detail="private diarization returned invalid JSON") from exc
    if not isinstance(result, dict) or not isinstance(result.get("segments"), list):
        raise HTTPException(status_code=502, detail="private diarization returned an invalid response")
    result.setdefault("raw_audio_persisted", False)
    return result


async def classify_realtime_speaker(
    wav_bytes: bytes,
) -> str:
    """Return a coarse owner/unknown label without retaining biometric scores."""
    if not SPEAKER_URL or not wav_bytes:
        return "unknown_voice"
    try:
        async with httpx.AsyncClient(timeout=20, trust_env=False) as client:
            response = await asyncio.wait_for(
                post(
                    client,
                    SPEAKER_URL + "/verify",
                    files={"audio": ("realtime-turn.wav", wav_bytes, "audio/wav")},
                    data={"profile": "owner"},
                ),
                timeout=20,
            )
        payload = response.json()
        if isinstance(payload, dict) and payload.get("accepted") is True:
            return "authorized_speaker"
    except (HTTPException, httpx.HTTPError, ValueError, TypeError, TimeoutError):
        pass
    return "unknown_voice"


async def generate_answer(
    client: httpx.AsyncClient,
    transcript: str,
    model: str,
    effort: int,
    tool_profile: str,
    history: list[dict[str, str]],
) -> tuple[str, str, dict]:
    selected_model = select_model(transcript, model, effort)
    response = await post(
        client,
        HOMEBLEND_URL + "/responses",
        json={
            "model": selected_model,
            "instructions": SYSTEM_INSTRUCTIONS,
            "input": [*history, {"role": "user", "content": transcript}],
            "stream": False,
            "metadata": {"homeblend_tool_profile": tool_profile},
        },
    )
    try:
        document = response.json()
        answer = extract_answer(document)
    except (ValueError, TypeError) as error:
        raise HTTPException(status_code=502, detail="private inference returned an invalid response") from error
    return answer, selected_model, document


async def synthesize_answer(client: httpx.AsyncClient, answer: str, voice: str | None) -> bytes:
    response = await post(
        client,
        SPEACHES_URL + "/audio/speech",
        json={
            "model": TTS_MODEL,
            "voice": (voice or DEFAULT_VOICE).strip(),
            "input": answer[:MAX_TTS_CHARACTERS],
            "response_format": "wav",
        },
    )
    if not response.content:
        raise HTTPException(status_code=502, detail="private speech synthesis returned empty audio")
    return response.content


async def transcribe_realtime_wav(
    client: httpx.AsyncClient,
    audio_bytes: bytes,
    model: str = FAST_STT_MODEL,
    use_server_denoiser: bool = True,
) -> str:
    if use_server_denoiser:
        audio_bytes = await denoise_audio_bytes(client, audio_bytes, "audio/wav")
    response = await post(
        client,
        SPEACHES_URL + "/audio/transcriptions",
        files={"file": ("realtime-turn.wav", audio_bytes, "audio/wav")},
        data={
            "model": model,
            "vad_filter": "true",
            "condition_on_previous_text": "false",
        },
    )
    try:
        payload = response.json()
    except ValueError as error:
        raise RuntimeError("private realtime transcription returned invalid JSON") from error
    transcript = payload.get("text") if isinstance(payload, dict) else None
    if not isinstance(transcript, str) or not transcript.strip():
        raise RuntimeError("private realtime transcription detected no speech")
    return transcript.strip()


async def stream_realtime_answer(
    client: httpx.AsyncClient,
    transcript: str,
    model: str,
    effort: int,
    tool_profile: str,
    history: list[dict[str, str]],
    result_metadata: dict,
    location: dict[str, float] | None,
    instructions: str = SYSTEM_INSTRUCTIONS,
):
    selected_model = select_model(transcript, model, effort)
    payload = {
        "model": selected_model,
        "instructions": instructions,
        "input": [*history, {"role": "user", "content": transcript}],
        "stream": True,
        "metadata": {
            "homeblend_tool_profile": tool_profile,
            **({"homeblend_location": location} if location else {}),
        },
    }
    try:
        async with client.stream("POST", HOMEBLEND_URL + "/responses", json=payload) as response:
            response.raise_for_status()
            async for line in response.aiter_lines():
                event = parse_sse_data_line(line)
                if event is None:
                    continue
                if event.get("type") == "error":
                    raise RuntimeError("private inference stream failed")
                if event.get("type") == "response.completed":
                    response_document = event.get("response")
                    if isinstance(response_document, dict):
                        metadata = response_document.get("metadata")
                        if isinstance(metadata, dict):
                            result_metadata.update(metadata)
                        usage = response_document.get("usage")
                        if isinstance(usage, dict):
                            result_metadata["usage"] = usage
                    continue
                if event.get("type") != "response.output_text.delta":
                    continue
                delta = event.get("delta")
                if isinstance(delta, str) and delta:
                    yield selected_model, delta
    except (httpx.ConnectError, httpx.TimeoutException) as error:
        raise RuntimeError("private realtime inference is unavailable") from error
    except httpx.HTTPStatusError as error:
        raise RuntimeError(f"private realtime inference returned HTTP {error.response.status_code}") from error


async def run_realtime_turn(
    session: VoiceSession,
    websocket: WebSocket,
    send_lock: asyncio.Lock,
    wav_bytes: bytes,
    history: BoundedConversation,
    *,
    model: str,
    effort: int,
    tool_profile: str,
    voice: str,
    turn_id: str,
    client_source: str,
    location: dict[str, float] | None,
    mode_config: VoiceModeConfig,
    transcript_override: str | None = None,
) -> None:
    """Complete one cancellable in-memory transcript -> model -> phrase-TTS turn."""

    async def send_json(event_type: str, **fields) -> None:
        async with send_lock:
            await websocket.send_json(control_message(event_type, **fields))

    async def send_audio(frame: AudioFrame) -> None:
        async with send_lock:
            await websocket.send_bytes(pack_audio_frame(frame))

    started_at = time.perf_counter()
    transcript_chars = 0
    response_chars = 0
    selected_model = ""
    result_metadata: dict = {}
    speaker_classification = "unknown_voice"
    speaker_task = asyncio.create_task(classify_realtime_speaker(wav_bytes)) \
        if wav_bytes else None

    async def resolve_speaker() -> str:
        nonlocal speaker_classification, speaker_task
        if speaker_task is not None:
            speaker_classification = await speaker_task
            speaker_task = None
        return speaker_classification

    effective_tool_profile = mode_config.effective_tool_profile(tool_profile)
    # The tiny model is appropriate for low-latency wake detection, but it is
    # too error-prone for the user's actual request. Realtime assistant/private
    # turns use the quality STT model; translation keeps the multilingual one.
    selected_stt_model = mode_config.effective_stt_model(
        STT_MODEL, MULTILINGUAL_STT_MODEL
    )
    # Browser and phone adapters already request platform echo cancellation and
    # noise suppression. A second enhancement pass can distort short proper
    # nouns (for example, Gauss -> gouse/girls), so reserve server denoising for
    # raw wearable microphones.
    use_server_denoiser = bool(
        session.device and session.device.kind not in {DeviceKind.BROWSER, DeviceKind.PHONE}
    )
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS, trust_env=False) as client:
            transcript = transcript_override
            if transcript is None:
                transcript = await transcribe_realtime_wav(
                    client, wav_bytes, selected_stt_model, use_server_denoiser
                )
            transcript_chars = len(transcript)
            session.handle(control_message("transcript.delta", final=True))
            await send_json("transcript.delta", text=transcript, final=True)
            mode_confirmation = intercept_mode_command(mode_config, transcript)
            # A command can mutate the profile for this and all following
            # turns. Recompute before audit or any possible inference.
            effective_tool_profile = mode_config.effective_tool_profile(tool_profile)

            phrase_buffer = PhraseBuffer(
                first_limit=TTS_FIRST_CHUNK_CHARACTERS,
                later_limit=TTS_STREAM_CHUNK_CHARACTERS,
            )
            answer_parts: list[str] = []
            audio_format: PcmFormat | None = None
            audio_sequence = 0
            sample_frames_sent = 0

            async def speak(phrase: str) -> None:
                nonlocal audio_format, audio_sequence, sample_frames_sent
                current_format = PcmFormat(24_000, 1)
                frame_bytes = max(
                    current_format.channels * current_format.sample_width_bytes,
                    current_format.sample_rate_hz * current_format.channels
                    * current_format.sample_width_bytes // 50,
                )
                pending = bytearray()
                async with client.stream(
                    "POST",
                    SPEACHES_URL + "/audio/speech",
                    json={
                        "model": TTS_MODEL,
                        "voice": voice,
                        "input": phrase,
                        "response_format": "pcm",
                        "sample_rate": current_format.sample_rate_hz,
                    },
                ) as upstream:
                    upstream.raise_for_status()
                    async for upstream_chunk in upstream.aiter_bytes():
                        if not upstream_chunk:
                            continue
                        if audio_format is None:
                            audio_format = current_format
                            session.handle(control_message("response.audio.started"))
                            await send_json(
                                "response.audio.started",
                                encoding="pcm16le",
                                sample_rate_hz=audio_format.sample_rate_hz,
                                channels=audio_format.channels,
                                playback=adapter_manifest(session.device.kind.value).playback,
                            )
                        elif current_format != audio_format:
                            raise RuntimeError("private TTS changed audio format during one response")
                        pending.extend(upstream_chunk)
                        while len(pending) >= frame_bytes:
                            chunk = bytes(pending[:frame_bytes])
                            del pending[:frame_bytes]
                            timestamp_ms = round(
                                1000 * sample_frames_sent / audio_format.sample_rate_hz
                            )
                            await send_audio(AudioFrame(
                                AudioKind.OUTPUT_PCM, audio_sequence, timestamp_ms, chunk
                            ))
                            audio_sequence += 1
                            sample_frames_sent += len(chunk) // (
                                audio_format.channels * audio_format.sample_width_bytes
                            )
                if pending:
                    if len(pending) % (current_format.channels * current_format.sample_width_bytes):
                        raise RuntimeError("private TTS returned unaligned PCM")
                    timestamp_ms = round(1000 * sample_frames_sent / current_format.sample_rate_hz)
                    chunk = bytes(pending)
                    await send_audio(AudioFrame(
                        AudioKind.OUTPUT_PCM, audio_sequence, timestamp_ms, chunk
                    ))
                    audio_sequence += 1
                    sample_frames_sent += len(chunk) // (
                        current_format.channels * current_format.sample_width_bytes
                    )

            if mode_confirmation is not None:
                # Keep the ordinary response lifecycle so every client reaches
                # a valid follow-up state, but never send the command to
                # HomeBlend or append it to conversational history.
                await send_json(
                    "mode.changed",
                    mode=mode_config.mode.value,
                    source_language=mode_config.source_language,
                    target_language=mode_config.target_language,
                )
                session.handle(control_message("response.text.delta"))
                await send_json(
                    "response.text.delta",
                    delta=mode_confirmation,
                    model="voice-core-local",
                )
                await speak(mode_confirmation)
                response_chars = len(mode_confirmation)
                await send_json(
                    "response.text.done",
                    text=f"You: {transcript}\n\nHomeBlend: {mode_confirmation}",
                    model="voice-core-local",
                )
                await send_json(
                    "response.audio.done",
                    frames=audio_sequence,
                    duration_ms=round(
                        1000 * sample_frames_sent / audio_format.sample_rate_hz
                    ) if audio_format else 0,
                )
                await resolve_speaker()
                await send_json(
                    "response.done", model="voice-core-local",
                    latency=session.trace.report(),
                    speaker_classification=speaker_classification,
                )
                write_voice_audit({
                    "status": "succeeded",
                    "session_id": session.session_id,
                    "turn_id": turn_id,
                    "device": session.device.kind.value if session.device else "unknown",
                    "client_source": client_source,
                    "speaker_classification": speaker_classification,
                    "speaker_classification_is_authentication": False,
                    "requested_route": model,
                    "selected_model": "voice-core-local",
                    "effort": effort,
                    "tool_profile": effective_tool_profile,
                    "voice_mode": mode_config.mode.value,
                    "stt_model": "client-transcript" if transcript_override is not None else selected_stt_model,
                    "server_denoiser_used": use_server_denoiser,
                    "mode_command": True,
                    "tool_calls": 0,
                    "tool_names": [],
                    "input_audio_bytes": len(wav_bytes),
                    "transcript_characters": transcript_chars,
                    "response_characters": response_chars,
                    "latency_ms": elapsed_ms(started_at),
                })
                return

            async for selected_model, delta in stream_realtime_answer(
                client,
                transcript,
                model,
                effort,
                effective_tool_profile,
                history.snapshot(),
                result_metadata,
                location,
                mode_config.instructions(SYSTEM_INSTRUCTIONS),
            ):
                session.handle(control_message("response.text.delta"))
                answer_parts.append(delta)
                await send_json("response.text.delta", delta=delta, model=selected_model)
                for phrase in phrase_buffer.feed(delta):
                    await speak(phrase)
            for phrase in phrase_buffer.flush():
                await speak(phrase)

            answer = "".join(answer_parts).strip()
            response_chars = len(answer)
            if not answer or audio_format is None:
                raise RuntimeError("private inference produced no speakable answer")
            history.append_turn(transcript, answer)
            display_answer = f"You: {transcript}\n\nHomeBlend: {answer}"
            await send_json("response.text.done", text=display_answer, model=selected_model)
            await send_json(
                "response.audio.done",
                frames=audio_sequence,
                duration_ms=round(1000 * sample_frames_sent / audio_format.sample_rate_hz),
            )
            await resolve_speaker()
            await send_json(
                "response.done", model=selected_model, latency=session.trace.report(),
                speaker_classification=speaker_classification,
            )
            write_voice_audit({
                "status": "succeeded",
                "session_id": session.session_id,
                "turn_id": turn_id,
                "device": session.device.kind.value if session.device else "unknown",
                "client_source": client_source,
                "speaker_classification": speaker_classification,
                "speaker_classification_is_authentication": False,
                "requested_route": model,
                "selected_model": selected_model,
                "effort": effort,
                "tool_profile": effective_tool_profile,
                "voice_mode": mode_config.mode.value,
                "stt_model": "client-transcript" if transcript_override is not None else selected_stt_model,
                "server_denoiser_used": use_server_denoiser,
                "tool_calls": int(result_metadata.get("tool_calls", 0) or 0),
                "tool_names": list(result_metadata.get("tool_names", [])),
                "input_audio_bytes": len(wav_bytes),
                "transcript_characters": transcript_chars,
                "response_characters": response_chars,
                "latency_ms": elapsed_ms(started_at),
            })
    except asyncio.CancelledError:
        if speaker_task is not None:
            speaker_task.cancel()
        write_voice_audit({
            "status": "cancelled",
            "session_id": session.session_id,
            "turn_id": turn_id,
            "client_source": client_source,
            "speaker_classification": "unknown_voice",
            "speaker_classification_is_authentication": False,
            "requested_route": model,
            "selected_model": selected_model or None,
            "tool_profile": effective_tool_profile,
            "voice_mode": mode_config.mode.value,
            "stt_model": "client-transcript" if transcript_override is not None else selected_stt_model,
            "server_denoiser_used": use_server_denoiser,
            "tool_calls": int(result_metadata.get("tool_calls", 0) or 0),
            "tool_names": list(result_metadata.get("tool_names", [])),
            "input_audio_bytes": len(wav_bytes),
            "transcript_characters": transcript_chars,
            "response_characters": response_chars,
            "latency_ms": elapsed_ms(started_at),
        })
        raise
    except Exception as error:
        if speaker_task is not None:
            speaker_task.cancel()
        write_voice_audit({
            "status": "failed",
            "error_type": type(error).__name__,
            "session_id": session.session_id,
            "turn_id": turn_id,
            "client_source": client_source,
            "speaker_classification": "unknown_voice",
            "speaker_classification_is_authentication": False,
            "requested_route": model,
            "selected_model": selected_model or None,
            "tool_profile": effective_tool_profile,
            "voice_mode": mode_config.mode.value,
            "stt_model": "client-transcript" if transcript_override is not None else selected_stt_model,
            "server_denoiser_used": use_server_denoiser,
            "tool_calls": int(result_metadata.get("tool_calls", 0) or 0),
            "tool_names": list(result_metadata.get("tool_names", [])),
            "input_audio_bytes": len(wav_bytes),
            "transcript_characters": transcript_chars,
            "response_characters": response_chars,
            "latency_ms": elapsed_ms(started_at),
        })
        if session.state.value in {"thinking", "speaking"}:
            session.handle(control_message("response.failed"))
        # Keep clients synchronized with the authoritative server state after
        # a failed turn. Without this event, the client can remain in
        # thinking/speaking and send an invalid barge-in while the server is
        # already armed for a new turn.
        await send_json("session.state", **session.snapshot(), failed=True)
        await send_json("error", code="turn_failed", detail=str(error)[:500])


def prune_speech_jobs(now: float | None = None) -> None:
    now = time.monotonic() if now is None else now
    expired = [job_id for job_id, (deadline, _, _) in speech_jobs.items() if deadline <= now]
    for job_id in expired:
        speech_jobs.pop(job_id, None)
    while len(speech_jobs) >= MAX_SPEECH_JOBS:
        speech_jobs.popitem(last=False)


@app.get("/health")
def health():
    security = security_state()
    security["application_auth"] = application_auth_state()
    return {
        "status": "ok",
        "service": "exocortex-private-voice",
        "raw_audio_persistence": False,
        "realtime_voice": {
            "enabled": REALTIME_ENABLED,
            "phase": "streaming-turns-beta",
            "protocol_version": 1,
        },
        "security": security,
    }


@app.get("/v2/voice/capabilities")
def realtime_capabilities():
    return JSONResponse({
        "protocol_version": 1,
        "phase": "streaming-turns-beta",
        "enabled": REALTIME_ENABLED,
        "adapters": {
            kind.value: adapter_manifest(kind.value).as_dict()
            for kind in DeviceKind
        },
        "audio": {
            "encoding": "pcm16le",
            "preferred_sample_rate_hz": 16_000,
            "preferred_channels": 1,
            "raw_audio_persistence": False,
        },
    }, headers={"Cache-Control": "no-store"})


@app.websocket("/v2/voice/realtime")
async def realtime_voice(websocket: WebSocket):
    """Run a cancellable, in-memory STT -> model -> phrase-TTS session."""
    if not REALTIME_ENABLED:
        await websocket.close(code=1013, reason="realtime voice is not enabled")
        return
    connection_id = secrets.token_hex(16)
    try:
        auth = authorize_client(
            websocket.headers,
            registry_path=REALTIME_CLIENT_REGISTRY,
            configured_hashes=REALTIME_CLIENT_TOKEN_SHA256,
            allow_unconfigured_loopback_proxy=REALTIME_ALLOW_TAILNET_UNAUTHENTICATED,
        )
    except RealtimeAuthConfigurationError:
        write_voice_audit({
            "event": "voice_authentication",
            "connection_id": connection_id,
            "decision": "error",
            "reason": "authentication_not_configured",
        })
        await websocket.close(code=1011, reason="realtime voice authentication is not configured")
        return
    auth_identity = {
        "client_id": auth.client.client_id if auth.client else None,
        "credential_id": auth.client.credential_id if auth.client else None,
    }
    audit_written = write_voice_audit({
        "event": "voice_authentication",
        "connection_id": connection_id,
        "decision": "allowed" if auth.authorized else "denied",
        "reason": auth.reason,
        **auth_identity,
    })
    if (
        auth.authorized
        and REALTIME_CLIENT_REGISTRY
        and not REALTIME_ALLOW_TAILNET_UNAUTHENTICATED
        and not audit_written
    ):
        await websocket.close(code=1013, reason="voice audit sink unavailable")
        return
    if not auth.authorized:
        failure_count = auth_failure_monitor.record_failure()
        if failure_count is not None:
            write_voice_audit({
                "event": "voice_authentication_alert",
                "connection_id": connection_id,
                "decision": "alert",
                "reason": "repeated_authentication_failures",
                "failure_count": failure_count,
                "window_seconds": round(auth_failure_monitor.window_seconds),
            })
        await websocket.close(code=1008, reason="realtime voice authentication required")
        return
    access_acquired = False
    if auth.client is not None:
        access_acquired = client_access.try_open(auth.client)
        if not access_acquired:
            write_voice_audit({
                "event": "voice_authentication",
                "connection_id": connection_id,
                "decision": "denied",
                "reason": "connection_limit",
                **auth_identity,
            })
            await websocket.close(code=1008, reason="realtime voice connection limit reached")
            return
    try:
        await websocket.accept(subprotocol=selected_websocket_subprotocol(websocket.headers))
    except Exception:
        if access_acquired and auth.client is not None:
            client_access.close(auth.client)
        write_voice_audit({
            "event": "voice_connection_closed",
            "connection_id": connection_id,
            "decision": "closed",
            "reason": "accept_failed",
            **auth_identity,
        })
        return
    session = VoiceSession(secrets.token_hex(16))
    coordinator = TurnCoordinator()
    send_lock = asyncio.Lock()
    history = BoundedConversation()
    turn_buffer: PcmTurnBuffer | None = None
    model = "auto"
    effort = 1
    tool_profile = "none"
    voice = DEFAULT_VOICE
    current_turn_id: str | None = None
    client_source = "unspecified"
    location: dict[str, float] | None = None
    mode_config = VoiceModeConfig()
    session_started_at = time.monotonic()
    max_session_seconds = (
        auth.client.max_session_seconds if auth.client else REALTIME_MAX_SESSION_SECONDS
    )

    async def send_json(event_type: str, **fields) -> None:
        async with send_lock:
            await websocket.send_json(control_message(event_type, **fields))

    await send_json(
        "session.ready", session_id=session.session_id,
        phase="streaming-turns-beta", audio_persistence=False,
    )
    try:
        while True:
            remaining_session_seconds = max_session_seconds - (time.monotonic() - session_started_at)
            if remaining_session_seconds <= 0:
                await websocket.close(code=1008, reason="realtime voice session lifetime reached")
                break
            try:
                message = await asyncio.wait_for(
                    websocket.receive(), timeout=remaining_session_seconds
                )
            except TimeoutError:
                await websocket.close(code=1008, reason="realtime voice session lifetime reached")
                break
            if message.get("type") == "websocket.disconnect":
                break
            if message.get("text") is not None:
                try:
                    event = parse_control_message(message["text"])
                    event_type = event["type"]
                    if (
                        auth.client is not None
                        and event_type in {"text.turn", "turn.commit"}
                        and not client_access.allow_request(auth.client)
                    ):
                        await send_json(
                            "error", code="rate_limited",
                            detail="realtime voice request limit reached",
                        )
                        continue
                    cancelled = False
                    committed_wav: bytes | None = None
                    committed_text: str | None = None
                    if event_type == "session.start":
                        model, effort, tool_profile = validate_options(
                            str(event.get("model", "auto")),
                            int(event.get("effort", 1)),
                            str(event.get("tool_profile", "none")),
                        )
                        # The current G2 prototype is Web-enabled by policy.
                        # This server-side default also repairs older cached
                        # clients that still send tool_profile=none.
                        if str(event.get("device", "")).strip().lower() == "g2":
                            tool_profile = "web"
                        requested_voice = str(event.get("voice", DEFAULT_VOICE)).strip()
                        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", requested_voice):
                            raise ProtocolError("voice contains unsupported characters")
                        voice = requested_voice
                        client_source = validate_client_source(event.get("source"))
                        location = validate_approximate_location(event.get("location"))
                        mode_config = configure_mode(
                            event.get("mode", "assistant"),
                            event.get("source_language"),
                            event.get("target_language"),
                        )
                    elif event_type in {"wake.detected", "turn.start", "speech.started"}:
                        candidate_turn_id = str(event.get("turn_id", ""))
                        current_turn_id = (
                            candidate_turn_id
                            if re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", candidate_turn_id)
                            else secrets.token_hex(16)
                        )
                    elif event_type == "text.turn":
                        candidate_turn_id = str(event.get("turn_id", ""))
                        current_turn_id = (
                            candidate_turn_id
                            if re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", candidate_turn_id)
                            else secrets.token_hex(16)
                        )
                        committed_text = str(event.get("text", "")).strip()
                        if not committed_text or len(committed_text) > 4_000:
                            raise ProtocolError("text.turn requires 1 to 4000 characters")
                        if "\x00" in committed_text:
                            raise ProtocolError("text.turn contains an unsupported character")
                    elif event_type == "turn.commit":
                        if turn_buffer is None:
                            raise ProtocolError("session.start is required before turn.commit")
                        committed_wav = turn_buffer.wav_bytes()
                    elif event_type == "turn.cancel":
                        if turn_buffer is None:
                            raise ProtocolError("session.start is required before turn.cancel")
                    elif event_type == "barge_in":
                        cancelled = await coordinator.cancel()
                    snapshot = session.handle(event)
                    if event_type == "session.start":
                        assert session.device is not None
                        turn_buffer = PcmTurnBuffer(PcmFormat(
                            session.device.input_sample_rate_hz,
                            session.device.input_channels,
                        ), MAX_AUDIO_BYTES)
                    elif event_type in {"wake.detected", "turn.start", "speech.started", "barge_in", "turn.cancel"}:
                        if turn_buffer is None:
                            raise ProtocolError("session.start is required before capturing audio")
                        turn_buffer.clear()
                    if event_type == "barge_in":
                        session.handle(control_message("response.cancelled"))
                    await send_json(
                        "session.state",
                        **snapshot,
                        cancelled_generation=cancelled,
                    )
                    if committed_wav is not None:
                        await coordinator.start(lambda _generation: run_realtime_turn(
                            session,
                            websocket,
                            send_lock,
                            committed_wav,
                            history,
                            model=model,
                            effort=effort,
                            tool_profile=tool_profile,
                            voice=voice,
                            turn_id=current_turn_id or secrets.token_hex(16),
                            client_source=client_source,
                            location=location,
                            mode_config=mode_config,
                        ))
                        current_turn_id = None
                    elif committed_text is not None:
                        text = committed_text
                        await coordinator.start(lambda _generation, text=text: run_realtime_turn(
                            session,
                            websocket,
                            send_lock,
                            b"",
                            history,
                            model=model,
                            effort=effort,
                            tool_profile=tool_profile,
                            voice=voice,
                            turn_id=current_turn_id or secrets.token_hex(16),
                            client_source=client_source,
                            location=location,
                            mode_config=mode_config,
                            transcript_override=text,
                        ))
                        current_turn_id = None
                    if event_type == "session.close":
                        break
                except (ProtocolError, ValueError) as error:
                    await send_json("error", code="invalid_control", detail=str(error))
            elif message.get("bytes") is not None:
                try:
                    frame = unpack_audio_frame(message["bytes"])
                    receipt = session.accept_audio(frame)
                    if turn_buffer is None:
                        raise ProtocolError("session.start is required before audio")
                    turn_buffer.append(frame.payload)
                    await send_json("audio.ack", **receipt)
                except ProtocolError as error:
                    await send_json("error", code="invalid_audio", detail=str(error))
    except WebSocketDisconnect:
        pass
    finally:
        await coordinator.cancel()
        if access_acquired and auth.client is not None:
            client_access.close(auth.client)
        write_voice_audit({
            "event": "voice_connection_closed",
            "connection_id": connection_id,
            "decision": "closed",
            "reason": "session_ended",
            "duration_ms": round((time.monotonic() - session_started_at) * 1000),
            **auth_identity,
        })


@app.get("/v1/voice/config")
def client_config():
    """Return non-secret, user-tunable foreground client settings."""
    return JSONResponse({
        "wake_word": WAKE_WORD,
        "wake_aliases": WAKE_ALIASES,
        "wake_clip_ms": WAKE_CLIP_MS,
        "wake_command_max_ms": WAKE_COMMAND_MAX_MS,
        "wake_silence_ms": WAKE_SILENCE_MS,
        "wake_recognition_bias": bool(WAKE_PROMPT or WAKE_HOTWORDS),
        "wake_stt_model": WAKE_STT_MODEL,
        "assistant_stt_model": STT_MODEL,
        "stt_modes": ["fast", "balanced"],
        "wake_engine": "sherpa-onnx-plus-private-whisper" if WAKE_URL and WAKE_ASR_FALLBACK else (
            "sherpa-onnx-zipformer-kws" if WAKE_URL else "whisper-pilot"
        ),
        "wake_asr_fallback": WAKE_ASR_FALLBACK,
        "wake_asr_rms_threshold": WAKE_ASR_RMS_THRESHOLD,
        "wake_detection_paths": ["denoised", "raw-fallback"] if DENOISER_URL else ["raw"],
        "denoiser": "DeepFilterNet3" if DENOISER_URL else "browser-only",
        "diarization": "Sortformer 4-speaker" if DIARIZATION_URL else "disabled",
        "conversation_reply_window_ms": CONVERSATION_REPLY_WINDOW_MS,
        "conversation_rearm_delay_ms": CONVERSATION_REARM_DELAY_MS,
        "stream_start_timeout_ms": STREAM_START_TIMEOUT_MS,
        "tts_stream_chunk_characters": TTS_STREAM_CHUNK_CHARACTERS,
        "tts_first_chunk_characters": TTS_FIRST_CHUNK_CHARACTERS,
        "streaming_tts": True,
        "voice_modes": ["assistant", "translation", "private"],
        "translation_default_target": "English",
        "multilingual_stt_configured": bool(MULTILINGUAL_STT_MODEL),
        "inline_text_turn": True,
    }, headers={"Cache-Control": "no-store"})


@app.post("/v1/voice/wake")
async def neural_wake(
    audio: Annotated[UploadFile, File()],
    session_id: Annotated[str, Form()],
):
    if not WAKE_URL:
        raise HTTPException(status_code=503, detail="dedicated neural wake service is not configured")
    raw_audio_bytes = await audio.read(MAX_AUDIO_BYTES + 1)
    content_type = audio.content_type or "application/octet-stream"
    filename = audio.filename or "wake-input"
    await audio.close()
    if not raw_audio_bytes or len(raw_audio_bytes) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="wake audio is empty or too large")
    async with httpx.AsyncClient(timeout=15, trust_env=False) as client:
        detection_inputs: list[tuple[str, bytes]] = []
        if DENOISER_URL:
            try:
                enhanced = await denoise_audio_bytes(client, raw_audio_bytes, content_type)
                detection_inputs.append(("denoised", enhanced))
            except HTTPException:
                # Wake detection is availability-sensitive and not an
                # authorization boundary. Browser WebRTC suppression plus the
                # raw KWS path is a safe fallback when enhancement is busy.
                pass
        detection_inputs.append(("raw", raw_audio_bytes))
        result: dict = {"heard": False}
        raw_rms = 0.0
        for path, candidate in detection_inputs:
            pcm = await pcm_for_wake(candidate)
            if path == "raw":
                raw_rms = pcm_float32_rms(pcm)
            path_session = session_id[:72] + ("-d" if path == "denoised" else "-r")
            response = await post(
                client,
                WAKE_URL + "/v1/wake/" + path_session,
                content=pcm,
                headers={"Content-Type": "application/octet-stream"},
            )
            try:
                result = response.json()
            except ValueError as exc:
                raise HTTPException(status_code=502, detail="neural wake service returned invalid JSON") from exc
            result["detection_path"] = path
            if result.get("heard"):
                result["detection_method"] = "neural_kws"
                break
        # Generic text-derived KWS can miss an owner's pronunciation. For a
        # speech-bearing miss only, ask the private tiny Whisper model whether
        # the utterance begins with a configured wake alias. This transcript is
        # diagnostic/detection-only and is never submitted as the question.
        use_whisper = bool(result.get("heard")) or (
            WAKE_ASR_FALLBACK and raw_rms >= WAKE_ASR_RMS_THRESHOLD
        )
        if use_whisper:
            replay = UploadFile(
                file=io.BytesIO(raw_audio_bytes),
                filename=filename,
                headers=Headers({"content-type": content_type}),
            )
            try:
                result["transcript"] = await transcribe_upload(
                    client, replay, allow_empty=True, wake_detection=True
                )
            except HTTPException:
                result["transcript"] = ""
            if not result.get("heard") and wake_transcript_matches(result["transcript"]):
                result["heard"] = True
                result["keyword"] = WAKE_WORD.upper()
                result["detection_method"] = "private_whisper_fallback"
        result["speech_rms"] = round(raw_rms, 6)
    result.setdefault("raw_audio_persisted", False)
    return JSONResponse(result, headers={"Cache-Control": "no-store"})


@app.post("/v1/voice/diarize")
async def diarize_upload(
    audio: Annotated[UploadFile, File()],
    consent: Annotated[bool, Form()] = False,
):
    """Proxy opt-in multi-speaker diarization without retaining raw audio."""
    if not DIARIZATION_URL:
        raise HTTPException(status_code=503, detail="private diarization is not configured")
    if not consent:
        raise HTTPException(status_code=403, detail="explicit participant consent is required")
    content = await audio.read(MAX_DIARIZATION_AUDIO_BYTES + 1)
    content_type = audio.content_type or "application/octet-stream"
    filename = audio.filename or "conversation-input"
    await audio.close()
    if not content or len(content) > MAX_DIARIZATION_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="audio is empty or exceeds configured limit")
    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS, trust_env=False) as client:
        result = await request_diarization(client, content, filename, content_type)
    return JSONResponse(result, headers={"Cache-Control": "no-store"})


@app.post("/v1/voice/transcript")
async def labeled_transcript(
    audio: Annotated[UploadFile, File()],
    consent: Annotated[bool, Form()] = False,
):
    """Return speaker-labeled text while keeping all raw audio in memory."""
    if not DIARIZATION_URL:
        raise HTTPException(status_code=503, detail="private diarization is not configured")
    if not consent:
        raise HTTPException(status_code=403, detail="explicit participant consent is required")
    content = await audio.read(MAX_DIARIZATION_AUDIO_BYTES + 1)
    content_type = audio.content_type or "application/octet-stream"
    filename = audio.filename or "conversation-input"
    await audio.close()
    if not content or len(content) > MAX_DIARIZATION_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="audio is empty or exceeds configured limit")
    started = time.perf_counter()
    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS, trust_env=False) as client:
        result = await request_diarization(client, content, filename, content_type)
        segments = result["segments"][:MAX_DIARIZATION_SEGMENTS]
        labeled: list[dict] = []
        for segment in segments:
            try:
                start_seconds = float(segment["start_seconds"])
                end_seconds = float(segment["end_seconds"])
                speaker = str(segment["speaker"])
            except (KeyError, TypeError, ValueError) as exc:
                raise HTTPException(status_code=502, detail="diarization segment was invalid") from exc
            wave = await slice_audio(content, start_seconds, end_seconds)
            upload = UploadFile(
                file=io.BytesIO(wave),
                filename="speaker-segment.wav",
                headers=Headers({"content-type": "audio/wav"}),
            )
            text = await transcribe_upload(client, upload, allow_empty=True)
            labeled.append({
                "start_seconds": start_seconds,
                "end_seconds": end_seconds,
                "speaker": speaker,
                "text": text,
            })
    return JSONResponse({
        "segments": labeled,
        "speaker_count": result.get("speaker_count", 0),
        "consent_recorded_for_request": True,
        "raw_audio_persisted": False,
        "derived_transcript_persisted": False,
        "elapsed_ms": elapsed_ms(started),
    }, headers={"Cache-Control": "no-store"})


@app.get("/", response_class=HTMLResponse)
def phone_client():
    with open("/app/client.html", encoding="utf-8") as handle:
        return HTMLResponse(handle.read(), headers={"Cache-Control": "no-store"})


@app.get("/speaker", response_class=HTMLResponse)
def speaker_client():
    with open("/app/speaker.html", encoding="utf-8") as handle:
        return HTMLResponse(handle.read(), headers={"Cache-Control": "no-store"})


@app.get("/transcript", response_class=HTMLResponse)
def transcript_client():
    with open("/app/transcript.html", encoding="utf-8") as handle:
        return HTMLResponse(handle.read(), headers={"Cache-Control": "no-store"})


async def speaker_json(client: httpx.AsyncClient, method: str, path: str, **kwargs) -> dict:
    try:
        response = await client.request(method, SPEAKER_URL + path, **kwargs)
    except (httpx.ConnectError, httpx.TimeoutException) as error:
        raise HTTPException(status_code=503, detail="private speaker service unavailable") from error
    try:
        payload = response.json()
    except (ValueError, TypeError) as error:
        raise HTTPException(status_code=502, detail="private speaker service returned an invalid response") from error
    if not response.is_success:
        detail = payload.get("detail", "private speaker service rejected the request") if isinstance(payload, dict) else "private speaker service rejected the request"
        status_code = response.status_code if response.status_code in {400, 409, 413, 422, 503} else 502
        raise HTTPException(status_code=status_code, detail=detail)
    if not isinstance(payload, dict):
        raise HTTPException(status_code=502, detail="private speaker service returned an invalid response")
    return payload


@app.get("/v1/voice/speaker/status")
async def speaker_status():
    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS, trust_env=False) as client:
        payload = await speaker_json(client, "GET", "/status", params={"profile": "owner"})
    return JSONResponse(payload, headers={"Cache-Control": "no-store"})


@app.post("/v1/voice/speaker/enroll")
async def speaker_enroll(audio: Annotated[list[UploadFile], File()]):
    if not 5 <= len(audio) <= 12:
        raise HTTPException(status_code=400, detail="provide 5-12 enrollment samples")
    files = []
    for index, upload in enumerate(audio):
        content = await upload.read(MAX_AUDIO_BYTES + 1)
        content_type = upload.content_type or "application/octet-stream"
        await upload.close()
        if not content or len(content) > MAX_AUDIO_BYTES:
            raise HTTPException(status_code=413, detail="an enrollment sample is empty or too large")
        files.append(("audio", (f"sample-{index}", content, content_type)))
    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS, trust_env=False) as client:
        payload = await speaker_json(
            client, "POST", "/enroll", files=files,
            data={"profile": "owner", "replace": "false"},
        )
    return JSONResponse(payload, headers={"Cache-Control": "no-store"})


@app.post("/v1/voice/speaker/verify")
async def speaker_verify(audio: Annotated[UploadFile, File()]):
    content = await audio.read(MAX_AUDIO_BYTES + 1)
    content_type = audio.content_type or "application/octet-stream"
    await audio.close()
    if not content or len(content) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="verification audio is empty or too large")
    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS, trust_env=False) as client:
        payload = await speaker_json(
            client, "POST", "/verify",
            files={"audio": ("verification", content, content_type)},
            data={"profile": "owner"},
        )
    return JSONResponse(payload, headers={"Cache-Control": "no-store"})


@app.post("/v1/voice/transcribe")
async def transcribe(
    audio: Annotated[UploadFile, File()],
    allow_empty: Annotated[bool, Form()] = False,
    wake_detection: Annotated[bool, Form()] = False,
    command_tail: Annotated[bool, Form()] = False,
    stt_mode: Annotated[str, Form()] = "fast",
    server_denoise: Annotated[bool, Form()] = True,
):
    start = time.perf_counter()
    # `allow_empty` was used exclusively by wake clips before the explicit
    # wake_detection field existed. Preserve fast wake recognition for an
    # already-open client tab during rolling upgrades.
    effective_wake_detection = wake_detection or (allow_empty and not command_tail)
    if stt_mode not in {"fast", "balanced"}:
        raise HTTPException(status_code=400, detail="stt_mode must be fast or balanced")
    requested_model = FAST_STT_MODEL if stt_mode == "fast" else STT_MODEL
    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS, trust_env=False) as client:
        transcript = await transcribe_upload(
            client,
            audio,
            allow_empty=allow_empty,
            wake_detection=effective_wake_detection,
            model_override=requested_model,
            use_server_denoiser=server_denoise,
        )
    return JSONResponse({
        "transcript": transcript,
        "speech_detected": bool(transcript),
        "wake_detection": effective_wake_detection,
        "stt_mode": stt_mode,
        "server_denoiser_used": server_denoise and bool(DENOISER_URL),
        "timing_ms": {"stt": elapsed_ms(start)},
        "security": security_state(),
    }, headers={"Cache-Control": "no-store"})


@app.post("/v1/voice/respond")
async def respond(
    text: Annotated[str, Form()],
    model: Annotated[str, Form()] = "auto",
    effort: Annotated[int, Form()] = 1,
    tool_profile: Annotated[str, Form()] = "none",
    history_json: Annotated[str | None, Form()] = None,
):
    transcript = text.strip()
    if not transcript:
        raise HTTPException(status_code=400, detail="text must not be empty")
    if len(transcript) > MAX_TEXT_CHARACTERS:
        raise HTTPException(status_code=413, detail="text exceeds configured size limit")
    try:
        model, effort, tool_profile = validate_options(model, effort, tool_profile)
        history = parse_history(history_json)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    start = time.perf_counter()
    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS, trust_env=False) as client:
        answer, selected_model, document = await generate_answer(
            client, transcript, model, effort, tool_profile, history
        )
    return JSONResponse({
        "transcript": transcript,
        "answer": answer,
        "selected_model": selected_model,
        "tool_profile": tool_profile,
        "tool_calls": int(document.get("metadata", {}).get("tool_calls", 0) or 0),
        "tool_names": document.get("metadata", {}).get("tool_names", []),
        "usage": document.get("usage", {}),
        "timing_ms": {"inference": elapsed_ms(start)},
        "security": security_state(),
    }, headers={"Cache-Control": "no-store"})


@app.post("/v1/voice/speech")
async def speech(
    text: Annotated[str, Form()],
    voice: Annotated[str | None, Form()] = None,
):
    answer = text.strip()
    if not answer:
        raise HTTPException(status_code=400, detail="text must not be empty")
    if len(answer) > MAX_TEXT_CHARACTERS:
        raise HTTPException(status_code=413, detail="text exceeds configured size limit")
    start = time.perf_counter()
    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS, trust_env=False) as client:
        audio = await synthesize_answer(client, answer, voice)
    return Response(audio, media_type="audio/wav", headers={
        "Cache-Control": "no-store",
        "X-Exocortex-TTS-Milliseconds": str(elapsed_ms(start)),
        "X-Exocortex-Audio-Truncated": str(len(answer) > MAX_TTS_CHARACTERS).lower(),
    })


@app.post("/v1/voice/speech-jobs")
async def create_speech_job(
    text: Annotated[str, Form()],
    voice: Annotated[str | None, Form()] = None,
):
    answer = text.strip()
    if not answer:
        raise HTTPException(status_code=400, detail="text must not be empty")
    if len(answer) > MAX_TEXT_CHARACTERS:
        raise HTTPException(status_code=413, detail="text exceeds configured size limit")
    prune_speech_jobs()
    speech_chunks = split_speech_text(answer[:MAX_TTS_CHARACTERS])
    job_ids: list[str] = []
    for speech_chunk in speech_chunks:
        prune_speech_jobs()
        job_id = secrets.token_urlsafe(32)
        speech_jobs[job_id] = (
            time.monotonic() + SPEECH_JOB_TTL_SECONDS,
            speech_chunk,
            voice,
        )
        job_ids.append(job_id)
    return JSONResponse({
        "job_id": job_ids[0],
        "job_ids": job_ids,
        "audio_mime_type": "audio/mpeg",
        "audio_truncated": len(answer) > MAX_TTS_CHARACTERS,
        "expires_in_seconds": SPEECH_JOB_TTL_SECONDS,
        "speech_chunks": len(speech_chunks),
    }, headers={"Cache-Control": "no-store"})


@app.get("/v1/voice/speech-stream/{job_id}")
async def stream_speech(job_id: str):
    prune_speech_jobs()
    job = speech_jobs.pop(job_id, None)
    if job is None:
        raise HTTPException(status_code=404, detail="speech stream is missing, expired, or already consumed")
    deadline, answer, voice = job
    if deadline <= time.monotonic():
        raise HTTPException(status_code=410, detail="speech stream expired")

    client = httpx.AsyncClient(timeout=TIMEOUT_SECONDS, trust_env=False)
    upstream_context = client.stream(
        "POST",
        SPEACHES_URL + "/audio/speech",
        json={
            "model": TTS_MODEL,
            "voice": (voice or DEFAULT_VOICE).strip(),
            "input": answer,
            "response_format": "mp3",
        },
    )
    try:
        upstream = await upstream_context.__aenter__()
        upstream.raise_for_status()
    except (httpx.ConnectError, httpx.TimeoutException) as error:
        await client.aclose()
        raise HTTPException(status_code=503, detail="private speech dependency unavailable") from error
    except httpx.HTTPStatusError as error:
        await client.aclose()
        raise HTTPException(status_code=502, detail="private speech synthesis failed") from error
    except Exception:
        await client.aclose()
        raise

    async def audio_bytes():
        try:
            async for chunk in upstream.aiter_bytes():
                if chunk:
                    yield chunk
        finally:
            await upstream_context.__aexit__(None, None, None)
            await client.aclose()

    # Each token represents one independently decodable MP3. The first token is
    # streamed directly into the browser; later tokens can be prefetched while
    # the current clip plays.
    return StreamingResponse(audio_bytes(), media_type="audio/mpeg", headers={
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
        "X-Exocortex-Speech-Chunks": "1",
    })


@app.post("/v1/voice/turn")
async def voice_turn(
    audio: Annotated[UploadFile | None, File()] = None,
    text: Annotated[str | None, Form()] = None,
    model: Annotated[str, Form()] = "auto",
    effort: Annotated[int, Form()] = 1,
    tool_profile: Annotated[str, Form()] = "none",
    voice: Annotated[str | None, Form()] = None,
    history_json: Annotated[str | None, Form()] = None,
):
    if (audio is None) == (not text or not text.strip()):
        raise HTTPException(status_code=400, detail="provide exactly one of audio or text")
    try:
        model, effort, tool_profile = validate_options(model, effort, tool_profile)
        history = parse_history(history_json)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    timings: dict[str, int] = {}
    total_start = time.perf_counter()
    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS, trust_env=False) as client:
        if audio is not None:
            stage = time.perf_counter()
            transcript = await transcribe_upload(client, audio)
            timings["stt"] = elapsed_ms(stage)
        else:
            transcript = str(text).strip()
            timings["stt"] = 0
        if len(transcript) > MAX_TEXT_CHARACTERS:
            raise HTTPException(status_code=413, detail="text exceeds configured size limit")

        stage = time.perf_counter()
        answer, selected_model, inference_document = await generate_answer(
            client, transcript, model, effort, tool_profile, history
        )
        timings["inference"] = elapsed_ms(stage)

        stage = time.perf_counter()
        speech = await synthesize_answer(client, answer, voice)
        timings["tts"] = elapsed_ms(stage)

    timings["total"] = elapsed_ms(total_start)
    return JSONResponse({
        "transcript": transcript,
        "answer": answer,
        "selected_model": selected_model,
        "tool_profile": tool_profile,
        "tool_calls": int(inference_document.get("metadata", {}).get("tool_calls", 0) or 0),
        "tool_names": inference_document.get("metadata", {}).get("tool_names", []),
        "usage": inference_document.get("usage", {}),
        "timing_ms": timings,
        "audio": base64.b64encode(speech).decode("ascii"),
        "audio_mime_type": "audio/wav",
        "audio_truncated": len(answer) > MAX_TTS_CHARACTERS,
        "security": security_state(),
    }, headers={"Cache-Control": "no-store"})


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host="127.0.0.1",
        port=int(os.environ.get("VOICE_GATEWAY_PORT", "8791")),
        access_log=False,
    )
