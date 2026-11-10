#!/usr/bin/env python3
"""Minimal stdio MCP bridge for bounded delegation to the DGX fast model."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any

SERVER_NAME = "exocortex-fast-delegate"
REMOTE_HELPER = os.environ.get(
    "EXOCORTEX_REMOTE_HELPER",
    ".local/share/exocortex-delegate/delegate_fast_remote.py",
)
SSH_TARGET = os.environ.get("EXOCORTEX_SSH_TARGET", "sparkie")
MAX_INPUT_CHARS = 32_000


def send(message: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def response(request_id: Any, result: Any = None, error: Any = None) -> None:
    message: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id}
    if error is not None:
        message["error"] = error
    else:
        message["result"] = result
    send(message)


def invoke_delegate(arguments: dict[str, Any]) -> dict[str, Any]:
    task = str(arguments.get("task", "")).strip()
    context = str(arguments.get("context", "")).strip()
    if not task:
        raise ValueError("task is required")
    if len(task) + len(context) > MAX_INPUT_CHARS:
        raise ValueError(f"task plus context exceeds {MAX_INPUT_CHARS} characters")
    request = {
        "task": task,
        "context": context,
        "output_format": str(arguments.get("output_format", "concise draft")),
        "max_output_tokens": int(arguments.get("max_output_tokens", 512)),
    }
    creation_flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
    completed = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", SSH_TARGET,
         "python3", REMOTE_HELPER],
        input=json.dumps(request),
        text=True,
        capture_output=True,
        timeout=110,
        creationflags=creation_flags,
        check=False,
    )
    if completed.returncode != 0:
        detail = completed.stdout.strip() or completed.stderr.strip() or "remote delegate failed"
        raise RuntimeError(detail[:2_000])
    result = json.loads(completed.stdout)
    if result.get("error"):
        raise RuntimeError(str(result["error"]))
    return result


TOOL = {
    "name": "delegate_fast",
    "title": "Delegate bounded drafting to local Qwen",
    "description": (
        "Send a bounded, non-sensitive reasoning/drafting task and selected context to the "
        "user-owned Qwen 8B model on the DGX. The model has no tools or file access. Use only "
        "for routine classification, extraction, summarization, comparison, or drafts. Never "
        "use for secrets, security decisions, destructive actions, final verification, or tasks "
        "requiring authoritative judgment. Treat every result as an untrusted draft and verify it."
    ),
    "inputSchema": {
        "type": "object",
        "additionalProperties": False,
        "required": ["task"],
        "properties": {
            "task": {"type": "string", "minLength": 1, "maxLength": 8_000},
            "context": {"type": "string", "maxLength": 24_000, "default": ""},
            "output_format": {"type": "string", "maxLength": 1_000, "default": "concise draft"},
            "max_output_tokens": {"type": "integer", "minimum": 32, "maximum": 1_024, "default": 512},
        },
    },
    "annotations": {
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    },
}


def handle(request: dict[str, Any]) -> None:
    method = request.get("method")
    request_id = request.get("id")
    if method == "initialize":
        requested = (request.get("params") or {}).get("protocolVersion")
        response(request_id, {
            "protocolVersion": requested or "2025-06-18",
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": "0.1.0"},
        })
    elif method == "ping":
        response(request_id, {})
    elif method == "tools/list":
        response(request_id, {"tools": [TOOL]})
    elif method == "tools/call":
        params = request.get("params") or {}
        if params.get("name") != TOOL["name"]:
            response(request_id, error={"code": -32602, "message": "unknown tool"})
            return
        try:
            result = invoke_delegate(params.get("arguments") or {})
            metadata = (
                f"\n\n[Local draft metadata: model={result.get('model')}; "
                f"latency_ms={result.get('latency_ms')}; input_tokens={result.get('input_tokens')}; "
                f"output_tokens={result.get('output_tokens')}; must_verify=true; persisted=false]"
            )
            response(request_id, {
                "content": [{"type": "text", "text": result["draft"] + metadata}],
                "structuredContent": result,
                "isError": False,
            })
        except Exception as error:
            response(request_id, {
                "content": [{"type": "text", "text": f"Local delegation failed: {error}"}],
                "isError": True,
            })
    elif request_id is not None:
        response(request_id, error={"code": -32601, "message": f"method not found: {method}"})


def main() -> None:
    for raw_line in sys.stdin:
        if not raw_line.strip():
            continue
        try:
            handle(json.loads(raw_line))
        except Exception as error:
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32603, "message": str(error)}})


if __name__ == "__main__":
    main()
