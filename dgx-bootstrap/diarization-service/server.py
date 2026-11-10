"""Consent-gated, in-memory NeMo Sortformer speaker diarization."""
from __future__ import annotations

import asyncio
import os
import subprocess
import threading
import time
from typing import Annotated

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse
import numpy as np


MODEL_NAME = os.environ.get(
    "DIARIZATION_MODEL", "nvidia/diar_streaming_sortformer_4spk-v2.1"
)
DEVICE = os.environ.get("DIARIZATION_DEVICE", "cpu")
MAX_AUDIO_BYTES = int(os.environ.get("DIARIZATION_MAX_AUDIO_BYTES", "100000000"))
MAX_PCM_BYTES = int(os.environ.get("DIARIZATION_MAX_PCM_BYTES", "230400000"))
MAX_CONCURRENT = int(os.environ.get("DIARIZATION_MAX_CONCURRENT", "1"))
SAMPLE_RATE = 16_000

app = FastAPI(title="Exocortex private diarization", docs_url=None, redoc_url=None)
model = None
model_lock = threading.Lock()
slots = threading.BoundedSemaphore(MAX_CONCURRENT)


def load_model():
    global model
    if model is None:
        import torch
        from nemo.collections.asr.models import SortformerEncLabelModel

        loaded = SortformerEncLabelModel.from_pretrained(
            model_name=MODEL_NAME, map_location=torch.device(DEVICE)
        )
        loaded.eval()
        loaded.freeze()
        model = loaded.to(torch.device(DEVICE))
    return model


def decode_audio(audio: bytes) -> np.ndarray:
    completed = subprocess.run(
        [
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", "pipe:0", "-ac", "1", "-ar", str(SAMPLE_RATE),
            "-f", "f32le", "pipe:1",
        ],
        input=audio,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=90,
        check=False,
    )
    if completed.returncode or not completed.stdout:
        raise HTTPException(status_code=422, detail="audio could not be decoded")
    if len(completed.stdout) > MAX_PCM_BYTES:
        raise HTTPException(status_code=413, detail="decoded audio duration exceeds configured limit")
    samples = np.frombuffer(completed.stdout, dtype="<f4").copy()
    if not samples.size or not np.isfinite(samples).all():
        raise HTTPException(status_code=422, detail="decoded audio was invalid")
    return samples


def parse_segments(lines: list[str]) -> list[dict]:
    segments: list[dict] = []
    for line in lines:
        # NeMo emits one line per segment: "start end speaker_N".
        fields = str(line).strip().split()
        if len(fields) < 3:
            continue
        try:
            start, end = float(fields[0]), float(fields[1])
        except ValueError:
            continue
        if end > start:
            segments.append({
                "start_seconds": round(start, 3),
                "end_seconds": round(end, 3),
                "speaker": fields[2],
            })
    return segments


def run_diarization(samples: np.ndarray) -> list[dict]:
    with model_lock:
        result = load_model().diarize(
            audio=samples,
            sample_rate=SAMPLE_RATE,
            batch_size=1,
            num_workers=0,
            verbose=False,
        )
    lines = result[0] if isinstance(result, list) and result else []
    return parse_segments(lines)


@app.on_event("startup")
def startup() -> None:
    load_model()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "exocortex-private-diarization",
        "model": MODEL_NAME,
        "device": DEVICE,
        "model_loaded": model is not None,
        "maximum_speakers": 4,
        "consent_required": True,
        "raw_audio_persistence": False,
        "temporary_audio_storage": "memory_only",
    }


@app.post("/v1/diarize")
async def diarize(
    audio: Annotated[UploadFile, File()],
    consent: Annotated[bool, Form()] = False,
):
    if not consent:
        raise HTTPException(status_code=403, detail="explicit participant consent is required")
    content = await audio.read(MAX_AUDIO_BYTES + 1)
    await audio.close()
    if not content or len(content) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="audio is empty or exceeds configured limit")
    if not slots.acquire(blocking=False):
        raise HTTPException(status_code=429, detail="diarizer is busy")
    started = time.perf_counter()
    try:
        samples = await asyncio.to_thread(decode_audio, content)
        segments = await asyncio.to_thread(run_diarization, samples)
    finally:
        slots.release()
    speakers = sorted({segment["speaker"] for segment in segments})
    return JSONResponse({
        "segments": segments,
        "speakers": speakers,
        "speaker_count": len(speakers),
        "consent_recorded_for_request": True,
        "raw_audio_persisted": False,
        "elapsed_ms": round((time.perf_counter() - started) * 1000),
    }, headers={"Cache-Control": "no-store"})


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000, access_log=False)
