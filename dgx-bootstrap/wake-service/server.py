"""Private streaming neural keyword spotting for the Gauss voice client."""
from __future__ import annotations

import asyncio
from collections import OrderedDict
import os
from pathlib import Path
import time

import numpy as np
import sentencepiece as spm
import sherpa_onnx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse


MODEL_DIR = Path("/opt/kws")
WAKE_WORD = os.environ.get("KWS_WAKE_WORD", "Gauss").strip() or "Gauss"
WAKE_ALIASES = tuple(dict.fromkeys(
    value.strip()
    for value in os.environ.get("KWS_WAKE_ALIASES", "Gauss,Goss,Gouse,Gauze").split(",")
    if value.strip()
))
SAMPLE_RATE = 16_000
MAX_CHUNK_BYTES = int(os.environ.get("KWS_MAX_CHUNK_BYTES", "640000"))
SESSION_TTL_SECONDS = int(os.environ.get("KWS_SESSION_TTL_SECONDS", "30"))
MAX_SESSIONS = int(os.environ.get("KWS_MAX_SESSIONS", "16"))
KEYWORDS_SCORE = float(os.environ.get("KWS_KEYWORDS_SCORE", "1.5"))
KEYWORDS_THRESHOLD = float(os.environ.get("KWS_KEYWORDS_THRESHOLD", "0.18"))
TAIL_PADDING_MS = min(max(int(os.environ.get("KWS_TAIL_PADDING_MS", "660")), 0), 1000)


def model_file(pattern: str) -> str:
    matches = sorted(MODEL_DIR.glob(pattern))
    if not matches:
        raise RuntimeError(f"missing KWS model artifact: {pattern}")
    return str(matches[0])


def make_keywords_file() -> Path:
    encoded = Path("/tmp/keywords.txt")
    tokenizer = spm.SentencePieceProcessor(model_file=str(MODEL_DIR / "bpe.model"))
    lines = []
    for alias in WAKE_ALIASES:
        pieces = tokenizer.encode(alias.upper(), out_type=str)
        if pieces:
            lines.append(
                " ".join(pieces)
                + f" :{KEYWORDS_SCORE} #{KEYWORDS_THRESHOLD} @{WAKE_WORD.upper()}"
            )
    if not lines:
        raise RuntimeError("wake words could not be encoded")
    encoded.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return encoded


keywords_file = make_keywords_file()
spotter = sherpa_onnx.KeywordSpotter(
    tokens=str(MODEL_DIR / "tokens.txt"),
    encoder=model_file("encoder-*.int8.onnx"),
    decoder=model_file("decoder-*.int8.onnx"),
    joiner=model_file("joiner-*.int8.onnx"),
    num_threads=int(os.environ.get("KWS_THREADS", "2")),
    max_active_paths=4,
    keywords_file=str(keywords_file),
    keywords_score=KEYWORDS_SCORE,
    keywords_threshold=KEYWORDS_THRESHOLD,
    # Fire at the end of GAUSS even when the user continues directly into a
    # command. Requiring a trailing blank delayed detection until a later clip.
    num_trailing_blanks=0,
    provider="cpu",
)
sessions: OrderedDict[str, tuple[float, object]] = OrderedDict()
decode_lock = asyncio.Lock()

app = FastAPI(title="Exocortex private neural wake service", docs_url=None, redoc_url=None)


def prune_sessions(now: float) -> None:
    for session_id, (last_seen, _) in list(sessions.items()):
        if now - last_seen > SESSION_TTL_SECONDS:
            sessions.pop(session_id, None)
    while len(sessions) >= MAX_SESSIONS:
        sessions.popitem(last=False)


def valid_session_id(value: str) -> str:
    if not 8 <= len(value) <= 80 or any(ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for ch in value):
        raise HTTPException(status_code=400, detail="invalid wake session id")
    return value


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "exocortex-neural-wake",
        "engine": "sherpa-onnx-zipformer-kws",
        "wake_word": WAKE_WORD,
        "wake_aliases": WAKE_ALIASES,
        "keywords_score": KEYWORDS_SCORE,
        "keywords_threshold": KEYWORDS_THRESHOLD,
        "sample_rate": SAMPLE_RATE,
        "raw_audio_persistence": False,
        "active_sessions": len(sessions),
    }


@app.post("/v1/wake/{session_id}")
async def detect(session_id: str, request: Request):
    session_id = valid_session_id(session_id)
    audio = await request.body()
    if not audio or len(audio) > MAX_CHUNK_BYTES or len(audio) % 4:
        raise HTTPException(status_code=400, detail="expected bounded little-endian float32 PCM")
    samples = np.frombuffer(audio, dtype="<f4")
    if not np.isfinite(samples).all():
        raise HTTPException(status_code=400, detail="PCM contains non-finite samples")
    samples = np.clip(samples, -1.0, 1.0)
    started = time.perf_counter()
    detected = ""
    async with decode_lock:
        now = time.monotonic()
        prune_sessions(now)
        if session_id not in sessions:
            sessions[session_id] = (now, spotter.create_stream())
        _, stream = sessions[session_id]
        sessions[session_id] = (now, stream)
        sessions.move_to_end(session_id)
        stream.accept_waveform(SAMPLE_RATE, samples)
        if TAIL_PADDING_MS:
            stream.accept_waveform(
                SAMPLE_RATE,
                np.zeros(SAMPLE_RATE * TAIL_PADDING_MS // 1000, dtype=np.float32),
            )
        while spotter.is_ready(stream):
            spotter.decode_stream(stream)
            result = spotter.get_result(stream)
            if result:
                detected = result
                spotter.reset_stream(stream)
                break
    return JSONResponse(
        {
            "heard": bool(detected),
            "keyword": detected,
            "engine": "sherpa-onnx-zipformer-kws",
            "timing_ms": round((time.perf_counter() - started) * 1000),
        },
        headers={"Cache-Control": "no-store"},
    )


@app.delete("/v1/wake/{session_id}")
def reset(session_id: str):
    sessions.pop(valid_session_id(session_id), None)
    return {"reset": True}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000, access_log=False)
