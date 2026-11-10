#!/usr/bin/env python3
"""Read-only Omi CV1 BLE firmware/privacy inventory.

This script never subscribes to live audio, downloads stored audio, clears the
ring, changes settings, or starts DFU. It reads the standard Device Information
Service, the Omi feature bitmask, the codec byte, and the storage status summary.

Install the optional runtime dependency with:  python -m pip install bleak
"""

from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import struct
import sys
from datetime import datetime, timezone


DIS = {
    "model": "00002a24-0000-1000-8000-00805f9b34fb",
    "serial": "00002a25-0000-1000-8000-00805f9b34fb",
    "firmware_revision": "00002a26-0000-1000-8000-00805f9b34fb",
    "hardware_revision": "00002a27-0000-1000-8000-00805f9b34fb",
    "software_revision": "00002a28-0000-1000-8000-00805f9b34fb",
    "manufacturer": "00002a29-0000-1000-8000-00805f9b34fb",
}

AUDIO_CODEC = "19b10002-e8f2-537e-4f6c-d104768a1214"
FEATURES = "19b10021-e8f2-537e-4f6c-d104768a1214"
STORAGE_STATUS = "30295782-4301-eabd-2904-2849adfeae43"

FEATURE_BITS = {
    0: "speaker",
    1: "accelerometer",
    2: "button",
    3: "battery",
    4: "usb",
    5: "haptic",
    6: "offline_storage",
    7: "led_dimming",
    8: "mic_gain",
}

CODECS = {
    0: "pcm_16_khz",
    1: "pcm_8_khz",
    10: "mulaw_16_khz",
    11: "mulaw_8_khz",
    20: "opus_16_khz",
}


async def safe_read(client, uuid: str) -> bytes | None:
    try:
        return bytes(await client.read_gatt_char(uuid))
    except Exception:
        return None


async def select_device(address: str | None, name: str, scan_seconds: float):
    if address:
        return address

    print(f"probe: scanning for {name!r}", file=sys.stderr, flush=True)
    from bleak import BleakScanner

    devices = await BleakScanner.discover(timeout=scan_seconds)
    matches = [device for device in devices if (device.name or "").lower() == name.lower()]
    if not matches:
        visible_names = sorted({device.name for device in devices if device.name})
        raise RuntimeError(
            f"No exact BLE name {name!r} found. Visible named devices: "
            + json.dumps(visible_names)
        )
    if len(matches) > 1:
        raise RuntimeError(
            f"Multiple matching pendants found ({len(matches)}); rerun with --address."
        )
    return matches[0]


async def probe(args: argparse.Namespace) -> dict:
    try:
        from bleak import BleakClient
    except ImportError as exc:
        raise RuntimeError("Missing dependency: install with `python -m pip install bleak`.")
    target = await select_device(args.address, args.name, args.scan_seconds)
    print("probe: connecting to selected pendant", file=sys.stderr, flush=True)
    async with BleakClient(target, timeout=args.connect_timeout) as client:
        print("probe: connected; reading inventory", file=sys.stderr, flush=True)
        services = []
        for service in client.services:
            services.append(
                {
                    "uuid": str(service.uuid).lower(),
                    "characteristics": [
                        {
                            "uuid": str(characteristic.uuid).lower(),
                            "properties": sorted(characteristic.properties),
                        }
                        for characteristic in service.characteristics
                    ],
                }
            )

        device_info = {}
        for label, uuid in DIS.items():
            value = await safe_read(client, uuid)
            if value is not None:
                device_info[label] = value.rstrip(b"\x00").decode("utf-8", errors="replace")

        feature_bytes = await safe_read(client, FEATURES)
        feature_mask = (
            int.from_bytes(feature_bytes[:4], "little")
            if feature_bytes is not None and len(feature_bytes) >= 4
            else None
        )

        codec_bytes = await safe_read(client, AUDIO_CODEC)
        codec_value = codec_bytes[0] if codec_bytes else None

        storage_bytes = await safe_read(client, STORAGE_STATUS)
        storage_status = None
        if storage_bytes is not None and len(storage_bytes) >= 16:
            used, unread_packets, free, rtc_valid = struct.unpack("<IIII", storage_bytes[:16])
            storage_status = {
                "used_bytes": used,
                "unread_packets": unread_packets,
                "free_bytes": free,
                "rtc_valid": bool(rtc_valid),
            }

        return {
            "probe_version": 1,
            "captured_at": datetime.now(timezone.utc).isoformat(),
            "read_only": True,
            "connected": client.is_connected,
            "address": getattr(target, "address", target if isinstance(target, str) else None),
            "name": getattr(target, "name", args.name),
            "device_information": device_info,
            "features": {
                "raw_mask": feature_mask,
                "enabled": (
                    [name for bit, name in FEATURE_BITS.items() if feature_mask & (1 << bit)]
                    if feature_mask is not None
                    else None
                ),
            },
            "audio_codec": {
                "raw_value": codec_value,
                "name": CODECS.get(codec_value, "unknown") if codec_value is not None else None,
            },
            "storage_status": storage_status,
            "gatt_services": services,
            "limitations": [
                "Device Information strings are not cryptographic firmware attestation.",
                "A successful unpaired read is evidence that the characteristic is not access-controlled.",
                "A failed read may reflect OS caching, pairing state, radio conditions, or firmware policy.",
                "This probe does not read or modify stored audio.",
            ],
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--address", help="Exact BLE address/identifier; skips name scan")
    parser.add_argument("--name", default="Omi", help="Exact advertised name (default: Omi)")
    parser.add_argument("--scan-seconds", type=float, default=12.0)
    parser.add_argument("--connect-timeout", type=float, default=20.0)
    parser.add_argument(
        "--overall-timeout",
        type=float,
        help="Hard wall-clock limit in seconds (default: scan + connect + 15)",
    )
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    overall_timeout = (
        args.overall_timeout
        if args.overall_timeout is not None
        else args.scan_seconds + args.connect_timeout + 15.0
    )
    if min(args.scan_seconds, args.connect_timeout, overall_timeout) <= 0:
        print(json.dumps({"error": "Timeout values must be greater than zero."}), file=sys.stderr)
        return 2

    # Windows' WinRT BLE backend can wedge while importing or initializing,
    # before an asyncio timeout has a chance to run. Keep the user-facing
    # process free of BLE imports and enforce the wall clock around a worker.
    if not args.worker:
        command = [sys.executable, str(__file__), *sys.argv[1:], "--worker"]
        process = subprocess.Popen(command)
        try:
            return process.wait(timeout=overall_timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            print(
                json.dumps(
                    {
                        "error": "Omi BLE inventory probe exceeded its hard timeout.",
                        "overall_timeout_seconds": overall_timeout,
                    },
                    indent=2,
                ),
                file=sys.stderr,
            )
            return 124

    try:
        result = asyncio.run(asyncio.wait_for(probe(args), timeout=overall_timeout))
    except KeyboardInterrupt:
        return 130
    except TimeoutError:
        print(
            json.dumps(
                {
                    "error": "Omi BLE inventory probe exceeded its hard timeout.",
                    "overall_timeout_seconds": overall_timeout,
                },
                indent=2,
            ),
            file=sys.stderr,
        )
        return 124
    except Exception as exc:
        print(json.dumps({"error": str(exc)}, indent=2), file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
