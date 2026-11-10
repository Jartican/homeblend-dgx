"""End-to-end smoke probe for browser WebSocket subprotocol authentication."""

from __future__ import annotations

import asyncio
import json
import os

import websockets


async def main() -> None:
    endpoint = os.environ.get(
        "VOICE_SMOKE_ENDPOINT", "ws://127.0.0.1:8791/v2/voice/realtime"
    )
    token = os.environ["VOICE_SMOKE_TOKEN"]
    async with websockets.connect(
        endpoint,
        subprotocols=["homeblend.voice.v1", f"auth.{token}"],
    ) as socket:
        assert socket.subprotocol == "homeblend.voice.v1"
        event = json.loads(await socket.recv())
        assert event["protocol_version"] == 1
        assert event["type"] == "session.ready"


if __name__ == "__main__":
    asyncio.run(main())
