#!/usr/bin/env python3
"""Private TCP bridge from Docker's host gateway to loopback-only LiteLLM.

The bridge does not inspect or persist payloads. LiteLLM still authenticates every
request. It must be bound only to the Docker bridge gateway, never 0.0.0.0.
"""
from __future__ import annotations

import argparse
import asyncio
import ipaddress


async def copy(source: asyncio.StreamReader, destination: asyncio.StreamWriter) -> None:
    try:
        while chunk := await source.read(65536):
            destination.write(chunk)
            await destination.drain()
    finally:
        try:
            destination.write_eof()
        except (AttributeError, OSError):
            pass


async def handle(client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter, target_host: str, target_port: int) -> None:
    try:
        target_reader, target_writer = await asyncio.open_connection(target_host, target_port)
    except OSError:
        client_writer.close()
        await client_writer.wait_closed()
        return
    await asyncio.gather(copy(client_reader, target_writer), copy(target_reader, client_writer))
    target_writer.close()
    client_writer.close()
    await asyncio.gather(target_writer.wait_closed(), client_writer.wait_closed(), return_exceptions=True)


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", type=int, default=14000)
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-port", type=int, default=4000)
    args = parser.parse_args()
    address = ipaddress.ip_address(args.bind)
    if address.is_unspecified or address.is_loopback or not address.is_private:
        raise SystemExit("--bind must be a private, non-loopback Docker bridge address")
    server = await asyncio.start_server(
        lambda reader, writer: handle(reader, writer, args.target_host, args.target_port),
        args.bind,
        args.port,
    )
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
