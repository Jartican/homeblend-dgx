"""Private TitaNet speaker-verification service; no raw audio persistence."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from typing import Annotated

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse

from core import centroid, similarity, validate_profile

MODEL_NAME = os.environ.get("SPEAKER_MODEL", "titanet_large")
DEVICE = os.environ.get("SPEAKER_DEVICE", "cpu")
THRESHOLD = min(max(float(os.environ.get("SPEAKER_THRESHOLD", "0.72")), 0.0), 1.0)
MAX_AUDIO_BYTES = int(os.environ.get("SPEAKER_MAX_AUDIO_BYTES", "20000000"))
MIN_ENROLLMENT_SAMPLES = min(max(int(os.environ.get("SPEAKER_MIN_ENROLLMENT_SAMPLES", "5")), 3), 20)
MAX_ENROLLMENT_SAMPLES = min(max(int(os.environ.get("SPEAKER_MAX_ENROLLMENT_SAMPLES", "12")), 5), 20)
VAULT_ROOT = Path(os.environ.get("SPEAKER_VAULT_ROOT", "/vault"))
VAULT_MARKER = VAULT_ROOT / ".luks2-verified"
PROFILE_ROOT = VAULT_ROOT / "voiceprints"

app = FastAPI(title="Exocortex private speaker verification", docs_url=None, redoc_url=None)
model = None
model_lock = threading.Lock()


def require_vault() -> None:
    if not VAULT_MARKER.is_file() or not PROFILE_ROOT.is_dir():
        raise HTTPException(status_code=503, detail="encrypted biometric vault is not mounted")


def profile_path(profile: str) -> Path:
    try:
        validated = validate_profile(profile)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    return PROFILE_ROOT / f"{validated}.json"


def load_model():
    global model
    if model is None:
        import torch
        from nemo.collections.asr.models import EncDecSpeakerLabelModel

        loaded = EncDecSpeakerLabelModel.from_pretrained(model_name=MODEL_NAME)
        loaded.eval()
        loaded.freeze()
        model = loaded.to(torch.device(DEVICE))
    return model


def convert_and_embed(audio_bytes: bytes, content_type: str) -> list[float]:
    suffix = ".webm" if "webm" in content_type else ".mp4" if "mp4" in content_type else ".input"
    with tempfile.TemporaryDirectory(prefix="speaker-") as directory:
        source = Path(directory) / ("audio" + suffix)
        wave = Path(directory) / "audio.wav"
        source.write_bytes(audio_bytes)
        try:
            subprocess.run(
                ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(source), "-ac", "1", "-ar", "16000", str(wave)],
                check=True,
                timeout=30,
            )
        except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            raise HTTPException(status_code=422, detail="audio could not be converted") from error
        with model_lock:
            embedding = load_model().get_embedding(str(wave)).detach().cpu().reshape(-1).tolist()
    return [float(value) for value in embedding]


async def read_audio(upload: UploadFile) -> tuple[bytes, str]:
    content = await upload.read(MAX_AUDIO_BYTES + 1)
    content_type = upload.content_type or "application/octet-stream"
    await upload.close()
    if not content:
        raise HTTPException(status_code=400, detail="audio was empty")
    if len(content) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=413, detail="audio exceeds configured size limit")
    return content, content_type


@app.on_event("startup")
def startup() -> None:
    load_model()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "service": "exocortex-private-speaker",
        "model": MODEL_NAME,
        "device": DEVICE,
        "model_loaded": model is not None,
        "encrypted_vault_ready": VAULT_MARKER.is_file() and PROFILE_ROOT.is_dir(),
        "raw_audio_persistence": False,
    }


@app.get("/v1/speaker/status")
def status(profile: str = "owner"):
    require_vault()
    path = profile_path(profile)
    return {"profile": validate_profile(profile), "enrolled": path.is_file(), "threshold": THRESHOLD}


@app.post("/v1/speaker/enroll")
async def enroll(
    audio: Annotated[list[UploadFile], File()],
    profile: Annotated[str, Form()] = "owner",
    replace: Annotated[bool, Form()] = False,
):
    require_vault()
    path = profile_path(profile)
    if path.exists() and not replace:
        raise HTTPException(status_code=409, detail="profile already exists; explicit replace is required")
    if not MIN_ENROLLMENT_SAMPLES <= len(audio) <= MAX_ENROLLMENT_SAMPLES:
        raise HTTPException(
            status_code=400,
            detail=f"provide {MIN_ENROLLMENT_SAMPLES}-{MAX_ENROLLMENT_SAMPLES} enrollment samples",
        )
    started = time.perf_counter()
    embeddings = []
    for upload in audio:
        content, content_type = await read_audio(upload)
        embeddings.append(convert_and_embed(content, content_type))
    profile_vector = centroid(embeddings)
    document = {
        "schema_version": "1.0",
        "profile": validate_profile(profile),
        "model": MODEL_NAME,
        "embedding": profile_vector,
        "sample_count": len(embeddings),
    }
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(document, separators=(",", ":")), encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
    return JSONResponse({
        "profile": document["profile"],
        "enrolled": True,
        "sample_count": len(embeddings),
        "raw_audio_persisted": False,
        "elapsed_ms": round((time.perf_counter() - started) * 1000),
    })


@app.post("/v1/speaker/verify")
async def verify(audio: Annotated[UploadFile, File()], profile: Annotated[str, Form()] = "owner"):
    require_vault()
    path = profile_path(profile)
    if not path.is_file():
        raise HTTPException(status_code=409, detail="speaker profile is not enrolled")
    try:
        enrolled = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as error:
        raise HTTPException(status_code=503, detail="speaker profile could not be read safely") from error
    if enrolled.get("model") != MODEL_NAME or not isinstance(enrolled.get("embedding"), list):
        raise HTTPException(status_code=409, detail="speaker profile is incompatible with the active model")
    content, content_type = await read_audio(audio)
    started = time.perf_counter()
    score = similarity(enrolled["embedding"], convert_and_embed(content, content_type))
    return JSONResponse({
        "profile": validate_profile(profile),
        "accepted": score >= THRESHOLD,
        "score": round(score, 6),
        "threshold": THRESHOLD,
        "raw_audio_persisted": False,
        "elapsed_ms": round((time.perf_counter() - started) * 1000),
    })


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000, access_log=False)
