"""Cancellation primitive for realtime STT, inference, tools, and TTS work."""
from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from typing import Any


class TurnCoordinator:
    """Own exactly one generation of asynchronous turn work at a time."""

    def __init__(self) -> None:
        self.generation = 0
        self._task: asyncio.Task[Any] | None = None

    @property
    def running(self) -> bool:
        return self._task is not None and not self._task.done()

    async def start(self, work: Callable[[int], Awaitable[Any]]) -> tuple[int, asyncio.Task[Any]]:
        await self.cancel()
        self.generation += 1
        generation = self.generation
        task = asyncio.create_task(work(generation), name=f"voice-turn-{generation}")
        self._task = task
        return generation, task

    async def cancel(self) -> bool:
        task = self._task
        if task is None or task.done():
            self._task = None
            return False
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        finally:
            self._task = None
        return True

    def is_current(self, generation: int) -> bool:
        return generation == self.generation
