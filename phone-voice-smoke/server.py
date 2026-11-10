#!/usr/bin/env python3
"""Localhost-only, no-log static server for the temporary phone test page."""

from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent


class PrivateHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def end_headers(self):
        requested_host = self.headers.get("Host", "").strip().lower()
        websocket_origin = ""
        if re.fullmatch(r"[a-z0-9.-]+(?::[0-9]{1,5})?", requested_host):
            websocket_origin = f" wss://{requested_host}"
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "microphone=(self), camera=(), geolocation=(self)")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
            f"connect-src 'self'{websocket_origin}; "
            "img-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
        )
        super().end_headers()

    def log_message(self, _format, *args):
        return


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8792), PrivateHandler).serve_forever()
