from __future__ import annotations

import asyncio
import sys

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


async def main() -> None:
    endpoint = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000/mcp"
    async with streamable_http_client(endpoint) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            names = {tool.name for tool in tools.tools}
            assert {"search_web", "fetch_url"}.issubset(names), names

            search = await session.call_tool(
                "search_web", {"query": "NVIDIA DGX Spark", "count": 3}
            )
            assert not search.isError, search
            structured = search.structuredContent or {}
            assert structured.get("results"), structured

            blocked = await session.call_tool(
                "fetch_url", {"url": "http://127.0.0.1:11434/api/tags"}
            )
            assert blocked.isError, "private-network fetch was not blocked"
            print("MCP tools discovered; public search works; private URL fetch blocked")


if __name__ == "__main__":
    asyncio.run(main())
