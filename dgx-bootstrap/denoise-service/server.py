"""In-memory DeepFilterNet3 speech enhancement for private voice audio."""
from __future__ import annotations

import ctypes
import asyncio
import os
import subprocess
import time

from deepfilternet_slim import runtime_assets
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response
import numpy as np


SAMPLE_RATE = 48_000
# DeepFilterNet3's shipped config uses fft_size=960, hop_size=480, and
# df_lookahead=2. The upstream enhancer compensates this algorithmic delay by
# flushing the filter and discarding the first 1,440 samples (30 ms).
ALGORITHMIC_DELAY_SAMPLES = 1_440
MAX_AUDIO_BYTES = int(os.environ.get("DENOISE_MAX_AUDIO_BYTES", "20000000"))
MAX_PCM_BYTES = int(os.environ.get("DENOISE_MAX_PCM_BYTES", "12000000"))
ATTENUATION_LIMIT_DB = float(os.environ.get("DENOISE_ATTENUATION_LIMIT_DB", "35"))
MAX_CONCURRENT = int(os.environ.get("DENOISE_MAX_CONCURRENT", "1"))
QUEUE_TIMEOUT_SECONDS = float(os.environ.get("DENOISE_QUEUE_TIMEOUT_SECONDS", "5"))
slots = asyncio.Semaphore(MAX_CONCURRENT)

assets = runtime_assets()
library = ctypes.CDLL(str(assets.library_path))
float_pointer = ctypes.POINTER(ctypes.c_float)
library.df_create.argtypes = [ctypes.c_char_p, ctypes.c_float, ctypes.c_char_p]
library.df_create.restype = ctypes.c_void_p
library.df_get_frame_length.argtypes = [ctypes.c_void_p]
library.df_get_frame_length.restype = ctypes.c_size_t
library.df_process_frame.argtypes = [ctypes.c_void_p, float_pointer, float_pointer]
library.df_process_frame.restype = ctypes.c_float
library.df_free.argtypes = [ctypes.c_void_p]
library.df_free.restype = None

app = FastAPI(title="Exocortex private denoiser", docs_url=None, redoc_url=None)


def ffmpeg(input_bytes: bytes, args: list[str]) -> bytes:
    completed = subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", *args],
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
        check=False,
    )
    if completed.returncode or not completed.stdout:
        raise HTTPException(status_code=422, detail="audio could not be decoded or encoded")
    return completed.stdout


def enhance_pcm(pcm: bytes) -> tuple[bytes, float]:
    samples = np.frombuffer(pcm, dtype="<f4")
    if not samples.size or not np.isfinite(samples).all():
        raise HTTPException(status_code=422, detail="decoded audio was invalid")
    state = library.df_create(
        str(assets.model_path).encode(),
        ctypes.c_float(ATTENUATION_LIMIT_DB),
        None,
    )
    if not state:
        raise HTTPException(status_code=503, detail="DeepFilterNet could not initialize")
    try:
        frame_length = int(library.df_get_frame_length(state))
        process_length = samples.size + ALGORITHMIC_DELAY_SAMPLES
        padded_length = ((process_length + frame_length - 1) // frame_length) * frame_length
        padded = np.zeros(padded_length, dtype=np.float32)
        padded[: samples.size] = samples
        enhanced = np.empty_like(padded)
        snr_values: list[float] = []
        for offset in range(0, padded_length, frame_length):
            source = np.ascontiguousarray(padded[offset : offset + frame_length])
            target = enhanced[offset : offset + frame_length]
            snr_values.append(float(library.df_process_frame(
                state,
                source.ctypes.data_as(float_pointer),
                target.ctypes.data_as(float_pointer),
            )))
        mean_snr = float(np.mean(snr_values)) if snr_values else 0.0
        compensated = enhanced[
            ALGORITHMIC_DELAY_SAMPLES : ALGORITHMIC_DELAY_SAMPLES + samples.size
        ]
        return compensated.astype("<f4", copy=False).tobytes(), mean_snr
    finally:
        library.df_free(state)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "exocortex-deepfilternet3",
        "engine": "DeepFilterNet3-ONNX-C",
        "runtime_version": assets.runtime_version,
        "upstream_commit": assets.deepfilternet_commit,
        "model_sha256": assets.model_sha256,
        "sample_rate": SAMPLE_RATE,
        "algorithmic_delay_compensated_samples": ALGORITHMIC_DELAY_SAMPLES,
        "raw_audio_persistence": False,
    }


@app.post("/v1/audio/enhance")
async def enhance_audio(request: Request):
    audio = await request.body()
    if not audio or len(audio) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="audio is empty or exceeds configured limit")
    try:
        await asyncio.wait_for(slots.acquire(), timeout=QUEUE_TIMEOUT_SECONDS)
    except TimeoutError as exc:
        raise HTTPException(status_code=503, detail="denoiser queue timed out") from exc
    started = time.perf_counter()
    try:
        pcm = await asyncio.to_thread(
            ffmpeg, audio,
            ["-i", "pipe:0", "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "f32le", "pipe:1"],
        )
        if len(pcm) > MAX_PCM_BYTES:
            raise HTTPException(status_code=413, detail="decoded audio duration exceeds configured limit")
        enhanced, mean_snr = await asyncio.to_thread(enhance_pcm, pcm)
        wav = await asyncio.to_thread(
            ffmpeg, enhanced,
            ["-f", "f32le", "-ar", str(SAMPLE_RATE), "-ac", "1", "-i", "pipe:0", "-c:a", "pcm_s16le", "-f", "wav", "pipe:1"],
        )
    finally:
        slots.release()
    return Response(
        wav,
        media_type="audio/wav",
        headers={
            "Cache-Control": "no-store",
            "X-Denoiser": "DeepFilterNet3",
            "X-Denoise-Milliseconds": str(round((time.perf_counter() - started) * 1000)),
            "X-Denoise-Mean-SNR": f"{mean_snr:.3f}",
        },
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000, access_log=False)
