#!/usr/bin/env python3
"""Send one PCM WAV through Voice Core v2 and save returned speech locally."""
from __future__ import annotations

import argparse
import asyncio
from io import BytesIO
import json
from pathlib import Path
import subprocess
import time
import uuid
import wave

import httpx
import websockets

from realtime_protocol import (
    AudioFrame,
    AudioKind,
    PROTOCOL_VERSION,
    pack_audio_frame,
    unpack_audio_frame,
)


DEVICE_FORMATS = {
    "browser": (16_000, 1),
    "halo": (8_000, 2),
    "g2": (16_000, 1),
}


def event(event_type: str, **fields) -> str:
    return json.dumps({"protocol_version": PROTOCOL_VERSION, "type": event_type, **fields})


def read_input(value: bytes | Path, device: str) -> tuple[int, int, bytes]:
    source_value = BytesIO(value) if isinstance(value, bytes) else str(value)
    with wave.open(source_value, "rb") as source:
        sample_rate = source.getframerate()
        channels = source.getnchannels()
        if source.getsampwidth() != 2 or source.getcomptype() != "NONE":
            raise ValueError("input must be an uncompressed signed 16-bit PCM WAV")
        expected = DEVICE_FORMATS[device]
        if (sample_rate, channels) != expected:
            raise ValueError(
                f"{device} input must be {expected[0]} Hz / {expected[1]} channel(s); "
                f"received {sample_rate} Hz / {channels}"
            )
        return sample_rate, channels, source.readframes(source.getnframes())


def write_output(path: Path, sample_rate: int, channels: int, pcm: bytes) -> None:
    with wave.open(str(path), "wb") as output:
        output.setframerate(sample_rate)
        output.setnchannels(channels)
        output.setsampwidth(2)
        output.writeframes(pcm)


def normalize_test_wav(value: bytes, device: str) -> bytes:
    """Convert synthetic TTS into the selected adapter's microphone format."""
    sample_rate, channels = DEVICE_FORMATS[device]
    completed = subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", "pipe:0",
            "-ar", str(sample_rate), "-ac", str(channels),
            "-c:a", "pcm_s16le", "-f", "wav", "pipe:1",
        ],
        input=value,
        capture_output=True,
        check=False,
        timeout=30,
    )
    if completed.returncode or not completed.stdout:
        raise RuntimeError("could not normalize the synthetic simulator input")
    return completed.stdout


async def simulate(args: argparse.Namespace) -> dict:
    if args.synthesize_text:
        async with httpx.AsyncClient(timeout=60, trust_env=False) as client:
            response = await client.post(
                args.speech_url,
                data={"text": args.synthesize_text, "voice": args.voice},
            )
            response.raise_for_status()
        input_value: bytes | Path = normalize_test_wav(response.content, args.device)
    elif args.input is not None:
        input_value = args.input
    else:
        raise ValueError("provide an input WAV or --synthesize-text")
    sample_rate, channels, pcm = read_input(input_value, args.device)
    text_parts: list[str] = []
    output_pcm = bytearray()
    output_format: tuple[int, int] | None = None
    committed_at = 0.0
    first_transcript_ms: int | None = None
    first_text_ms: int | None = None
    first_audio_ms: int | None = None
    result: dict = {}
    audio_done = False
    verification_transcript: str | None = None
    barge_sent_at: float | None = None

    async with websockets.connect(args.url, max_size=2**20) as socket:
        ready = json.loads(await socket.recv())
        if ready.get("type") != "session.ready":
            raise RuntimeError(f"unexpected first event: {ready}")
        await socket.send(event(
            "session.start",
            device=args.device,
            model=args.model,
            effort=args.effort,
            tool_profile=args.tool_profile,
            voice=args.voice,
        ))
        await socket.send(event("turn.start", turn_id="sim-" + uuid.uuid4().hex))

        frame_bytes = sample_rate * channels * 2 // 50
        sample_frames_sent = 0
        for sequence, offset in enumerate(range(0, len(pcm), frame_bytes)):
            chunk = pcm[offset : offset + frame_bytes]
            await socket.send(pack_audio_frame(AudioFrame(
                AudioKind.INPUT_PCM,
                sequence,
                round(1000 * sample_frames_sent / sample_rate),
                chunk,
            )))
            sample_frames_sent += len(chunk) // (channels * 2)
        committed_at = time.monotonic()
        await socket.send(event("turn.commit"))

        while True:
            message = await socket.recv()
            if isinstance(message, bytes):
                frame = unpack_audio_frame(message)
                if frame.kind != AudioKind.OUTPUT_PCM:
                    raise RuntimeError("server returned a non-output audio frame")
                output_pcm.extend(frame.payload)
                continue
            response = json.loads(message)
            event_type = response.get("type")
            if event_type == "error":
                raise RuntimeError(f"{response.get('code')}: {response.get('detail')}")
            if event_type == "transcript.delta" and first_transcript_ms is None:
                first_transcript_ms = round((time.monotonic() - committed_at) * 1000)
            elif event_type == "response.text.delta":
                if first_text_ms is None:
                    first_text_ms = round((time.monotonic() - committed_at) * 1000)
                text_parts.append(str(response.get("delta", "")))
                if args.barge_after_first_text and barge_sent_at is None:
                    barge_sent_at = time.monotonic()
                    await socket.send(event("barge_in"))
            elif (
                event_type == "session.state"
                and barge_sent_at is not None
                and response.get("state") == "capturing"
            ):
                cancelled_ms = round((time.monotonic() - barge_sent_at) * 1000)
                await socket.send(event("session.close"))
                return {
                    "commit_to_transcript_ms": first_transcript_ms,
                    "commit_to_first_text_ms": first_text_ms,
                    "barge_in_cancel_ms": cancelled_ms,
                    "cancelled_generation": bool(response.get("cancelled_generation")),
                }
            elif event_type == "response.audio.started":
                first_audio_ms = round((time.monotonic() - committed_at) * 1000)
                output_format = (
                    int(response["sample_rate_hz"]),
                    int(response["channels"]),
                )
            elif event_type == "response.done":
                result = response
                if audio_done:
                    break
            elif event_type == "response.audio.done":
                audio_done = True

        if output_format is None or not output_pcm:
            raise RuntimeError("server returned no output audio")
        write_output(args.output, output_format[0], output_format[1], bytes(output_pcm))
        await socket.send(event("playback.finished"))
        await socket.send(event("session.close"))

    if args.verify_output:
        async with httpx.AsyncClient(timeout=60, trust_env=False) as client:
            response = await client.post(
                args.transcribe_url,
                files={"audio": (args.output.name, args.output.read_bytes(), "audio/wav")},
                data={"mode": "fast"},
            )
            response.raise_for_status()
            verification = response.json()
            verification_transcript = str(verification.get("transcript", "")).strip()
            if not verification_transcript:
                raise RuntimeError("streamed output did not produce a verification transcript")

    return {
        "commit_to_transcript_ms": first_transcript_ms,
        "commit_to_first_text_ms": first_text_ms,
        "commit_to_first_audio_ms": first_audio_ms,
        "answer": "".join(text_parts).strip(),
        "audio_output": str(args.output),
        "verification_transcript": verification_transcript,
        "server": result,
    }


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("input", type=Path, nargs="?", help="16-bit PCM WAV matching the selected device")
    result.add_argument("--output", type=Path, default=Path("voice-v2-output.wav"))
    result.add_argument("--url", default="ws://127.0.0.1:8791/v2/voice/realtime")
    result.add_argument("--speech-url", default="http://127.0.0.1:8791/v1/voice/speech")
    result.add_argument("--transcribe-url", default="http://127.0.0.1:8791/v1/voice/transcribe")
    result.add_argument("--synthesize-text", help="create an in-memory test input through private TTS")
    result.add_argument("--verify-output", action="store_true")
    result.add_argument("--barge-after-first-text", action="store_true")
    result.add_argument("--device", choices=sorted(DEVICE_FORMATS), default="browser")
    result.add_argument("--model", choices=("auto", "8b", "27b"), default="8b")
    result.add_argument("--effort", type=int, choices=range(1, 6), default=1)
    result.add_argument("--tool-profile", choices=("none", "web"), default="none")
    result.add_argument("--voice", default="af_heart")
    return result


if __name__ == "__main__":
    print(json.dumps(asyncio.run(simulate(parser().parse_args())), indent=2))
