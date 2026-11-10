"""End-to-end probe for the temporary loopback/Tailscale migration mode."""

from __future__ import annotations

import asyncio
import json
import os

import websockets


async def main() -> None:
    endpoint = os.environ.get(
        "VOICE_SMOKE_ENDPOINT", "ws://127.0.0.1:8791/v2/voice/realtime"
    )
    async with websockets.connect(endpoint) as socket:
        event = json.loads(await socket.recv())
        assert event["protocol_version"] == 1
        assert event["type"] == "session.ready"


if __name__ == "__main__":
    asyncio.run(main())
