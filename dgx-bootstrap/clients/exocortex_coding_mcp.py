#!/usr/bin/env python3
"""Stdio MCP bridge for tested, shadow-only Qwen coding proposals."""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path, PurePosixPath
from typing import Any

SERVER_NAME = "exocortex-coding-delegate"
SSH_TARGET = os.environ.get("EXOCORTEX_SSH_TARGET", "sparkie")
LAB_ROOT = Path(os.environ.get("EXOCORTEX_OFFLOAD_LAB", Path(__file__).resolve().parents[2] / "experiments" / "offload_lab")).resolve()
sys.path.insert(0, str(LAB_ROOT))

from coding_lab.sandbox import DockerSandbox  # noqa: E402
from coding_lab.worktree import propose  # noqa: E402


def send(value: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def respond(request_id: Any, result: Any = None, error: Any = None) -> None:
    value: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id}
    value["error" if error is not None else "result"] = error if error is not None else result
    send(value)


def free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def validate_allowed(values: list[str]) -> list[str]:
    if not values or len(values) > 8:
        raise ValueError("allowed_paths must contain 1 to 8 paths")
    for value in values:
        path = PurePosixPath(value.replace("\\", "/"))
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"unsafe allowed path: {value}")
    return values


def invoke(arguments: dict[str, Any]) -> dict[str, Any]:
    DockerSandbox.verify_available()
    repo = Path(str(arguments.get("repo", ""))).resolve()
    prompt = str(arguments.get("task", "")).strip()
    allowed = validate_allowed([str(x) for x in arguments.get("allowed_paths", [])])
    test_command = str(arguments.get("test_command", "")).strip()
    if not prompt or len(prompt) > 8_000:
        raise ValueError("task must contain 1 to 8,000 characters")
    if not test_command or len(test_command) > 1_000:
        raise ValueError("test_command must contain 1 to 1,000 characters")
    if not (repo / ".git").exists():
        raise ValueError("repo must be an existing Git worktree")
    port = free_port()
    creation_flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    tunnel = subprocess.Popen(
        ["ssh", "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
         "-L", f"127.0.0.1:{port}:127.0.0.1:4000", SSH_TARGET],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, creationflags=creation_flags,
    )
    try:
        time.sleep(0.8)
        if tunnel.poll() is not None:
            raise RuntimeError("SSH tunnel failed")
        key_result = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", SSH_TARGET,
             "sed -n 's/^LITELLM_KEY=//p' ~/.config/exocortex/stack.env"],
            capture_output=True, text=True, timeout=20, check=False, creationflags=creation_flags,
        )
        key = key_result.stdout.splitlines()[0].strip() if key_result.returncode == 0 and key_result.stdout.splitlines() else ""
        if not key:
            raise RuntimeError("LiteLLM key retrieval failed")
        provider = {
            "base_url": f"http://127.0.0.1:{port}/v1", "api_key": key,
            "model": "exocortex-agent-quality", "temperature": 0,
            "max_tokens": 2048, "timeout_seconds": 240,
        }
        output = LAB_ROOT / "runs" / "mcp-proposals" / uuid.uuid4().hex
        result = propose(repo, prompt, allowed, test_command, provider, output, mode="shadow", max_turns=8)
        return {
            "decision": result["decision"], "model": result["model"],
            "latency_ms": result["agent"]["latency_ms"],
            "local_tokens": result["agent"]["usage"]["input_tokens"] + result["agent"]["usage"]["output_tokens"],
            "tests_passed": result["grade"]["exit_code"] == 0,
            "safety_passed": result["grade"]["safety_passed"],
            "patch_path": str(output / "proposal.patch"),
            "result_path": str(output / "result.json"),
            "source_modified": False, "mode": "shadow",
        }
    finally:
        tunnel.terminate()
        try:
            tunnel.wait(timeout=5)
        except subprocess.TimeoutExpired:
            tunnel.kill()


TOOL = {
    "name": "propose_code_patch",
    "title": "Create a tested local-Qwen shadow patch",
    "description": (
        "Ask the user-owned Qwen 27B model to edit a disposable copy of a Git worktree, "
        "then run one fixed test command in a network-disabled Docker container. The source "
        "worktree is never modified. Use only for bounded low/medium-risk coding tasks with "
        "explicit write paths. Treat the returned patch as untrusted shadow evidence; Codex "
        "must inspect it. Never use for secrets, credentials, security-sensitive code, migrations, "
        "destructive work, or repositories the user has not authorized for local-model processing."
    ),
    "inputSchema": {"type": "object", "additionalProperties": False,
        "required": ["repo", "task", "allowed_paths", "test_command"],
        "properties": {
            "repo": {"type": "string"}, "task": {"type": "string", "maxLength": 8000},
            "allowed_paths": {"type": "array", "minItems": 1, "maxItems": 8, "items": {"type": "string"}},
            "test_command": {"type": "string", "maxLength": 1000},
        }},
    "annotations": {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": False, "openWorldHint": False},
}


def handle(request: dict[str, Any]) -> None:
    method, request_id = request.get("method"), request.get("id")
    if method == "initialize":
        version = (request.get("params") or {}).get("protocolVersion", "2025-06-18")
        respond(request_id, {"protocolVersion": version, "capabilities": {"tools": {"listChanged": False}}, "serverInfo": {"name": SERVER_NAME, "version": "0.1.0"}})
    elif method == "ping": respond(request_id, {})
    elif method == "tools/list": respond(request_id, {"tools": [TOOL]})
    elif method == "tools/call":
        if (request.get("params") or {}).get("name") != TOOL["name"]:
            respond(request_id, error={"code": -32602, "message": "unknown tool"}); return
        try:
            result = invoke((request.get("params") or {}).get("arguments") or {})
            respond(request_id, {"content": [{"type": "text", "text": json.dumps(result, indent=2)}], "structuredContent": result, "isError": False})
        except Exception as error:
            respond(request_id, {"content": [{"type": "text", "text": f"Coding shadow delegation unavailable: {error}"}], "isError": True})
    elif request_id is not None: respond(request_id, error={"code": -32601, "message": f"method not found: {method}"})


def main() -> None:
    for line in sys.stdin:
        if line.strip(): handle(json.loads(line))


if __name__ == "__main__": main()
