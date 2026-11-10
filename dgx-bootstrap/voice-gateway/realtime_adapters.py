"""Versioned capability manifests for glasses and fallback clients."""
from __future__ import annotations

from dataclasses import asdict, dataclass

from realtime_core import DEVICE_PROFILES, DeviceCapabilities, DeviceKind, playback_target


@dataclass(frozen=True, slots=True)
class AdapterManifest:
    adapter_id: str
    device: DeviceCapabilities
    capture_format: str
    transport: str
    playback: str
    display_partial_transcripts: bool
    notes: tuple[str, ...]

    def as_dict(self) -> dict:
        value = asdict(self)
        value["device"]["kind"] = self.device.kind.value
        return value


def adapter_manifest(kind: str, *, external_audio_available: bool = False) -> AdapterManifest:
    try:
        device_kind = DeviceKind(kind)
    except ValueError as error:
        raise ValueError(f"unsupported realtime voice adapter: {kind}") from error
    device = DEVICE_PROFILES[device_kind]
    if device_kind == DeviceKind.HALO:
        return AdapterManifest(
            adapter_id="brilliant-halo-v1",
            device=device,
            capture_format="pcm16le",
            transport="native-companion-ble-to-websocket",
            playback=playback_target(device),
            display_partial_transcripts=True,
            notes=("enable device AEC", "enable voice-band mode", "use audio activity events"),
        )
    if device_kind == DeviceKind.G2:
        return AdapterManifest(
            adapter_id="even-g2-v1",
            device=device,
            capture_format="pcm16le",
            transport="even-hub-phone-plugin-to-websocket",
            playback=playback_target(device, external_audio_available),
            display_partial_transcripts=True,
            notes=("glasses have no speaker", "use phone or paired earbuds for TTS"),
        )
    if device_kind == DeviceKind.PHONE:
        return AdapterManifest(
            adapter_id="native-phone-v1",
            device=device,
            capture_format="pcm16le",
            transport="native-companion-websocket",
            playback=playback_target(device),
            display_partial_transcripts=True,
            notes=("use native echo cancellation", "memory-only PCM buffers"),
        )
    return AdapterManifest(
        adapter_id="browser-diagnostic-v1",
        device=device,
        capture_format="browser-media",
        transport="foreground-browser-http-fallback",
        playback=playback_target(device),
        display_partial_transcripts=True,
        notes=("diagnostic fallback only", "not the production glasses transport"),
    )
