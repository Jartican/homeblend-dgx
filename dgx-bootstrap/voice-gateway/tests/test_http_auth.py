import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import server
from realtime_auth import ClientAccessController


TOKEN = "v" * 48
TOKEN_HASH = hashlib.sha256(TOKEN.encode("utf-8")).hexdigest()


class HttpVoiceAuthenticationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(
            dir=Path(__file__).resolve().parent
        )
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.registry = self.root / "clients.json"
        self.audit = self.root / "audit.jsonl"
        self.registry.write_text(json.dumps({
            "schema_version": 1,
            "clients": [{
                "client_id": "iphone-primary",
                "credential_id": "iphone-primary-test",
                "token_sha256": TOKEN_HASH,
                "created_at": "2026-10-01T00:00:00Z",
                "expires_at": "2035-10-01T00:00:00Z",
                "enabled": True,
                "max_connections": 2,
                "max_requests_per_minute": 30,
                "max_session_seconds": 3600,
            }],
        }), encoding="utf-8")

    def configured_client(self, *, bridge=False, registry=None, audit=None):
        values = {
            "REALTIME_ENABLED": True,
            "REALTIME_CLIENT_REGISTRY": str(registry or self.registry),
            "REALTIME_CLIENT_TOKEN_SHA256": "",
            "REALTIME_ALLOW_TAILNET_UNAUTHENTICATED": bridge,
            "AUDIT_LOG_PATH": str(audit or self.audit),
            "client_access": ClientAccessController(),
            "_audit_sink_error": False,
        }
        return patch.multiple(server, **values)

    def test_missing_and_wrong_credentials_are_rejected(self):
        with self.configured_client(), TestClient(server.app) as client:
            missing = client.get("/v1/voice/config")
            wrong = client.get(
                "/v1/voice/config",
                headers={"Authorization": "Bearer " + ("x" * 48)},
            )
        self.assertEqual(missing.status_code, 401)
        self.assertEqual(wrong.status_code, 401)
        self.assertEqual(missing.headers["www-authenticate"], "Bearer")

    def test_invalid_registry_fails_closed(self):
        invalid = self.root / "invalid.json"
        invalid.write_text("{}", encoding="utf-8")
        with self.configured_client(registry=invalid), TestClient(server.app) as client:
            response = client.get(
                "/v1/voice/config",
                headers={"Authorization": "Bearer " + TOKEN},
            )
        self.assertEqual(response.status_code, 503)

    def test_valid_credential_reaches_route_and_is_audited(self):
        with self.configured_client(), TestClient(server.app) as client:
            response = client.get(
                "/v1/voice/config",
                headers={"Authorization": "Bearer " + TOKEN},
            )
            health = client.get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertTrue(self.audit.is_file())
        record = json.loads(self.audit.read_text(encoding="utf-8").splitlines()[0])
        self.assertEqual(record["decision"], "allowed")
        self.assertNotIn(TOKEN, self.audit.read_text(encoding="utf-8"))
        self.assertTrue(health.json()["security"]["application_auth"]["production_ready"])

    def test_production_request_fails_when_audit_sink_is_unwritable(self):
        missing_parent = self.root / "missing" / "audit.jsonl"
        with self.configured_client(audit=missing_parent), TestClient(server.app) as client:
            response = client.get(
                "/v1/voice/config",
                headers={"Authorization": "Bearer " + TOKEN},
            )
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json()["detail"], "voice audit sink unavailable")

    def test_production_websocket_fails_when_audit_sink_is_unwritable(self):
        missing_parent = self.root / "missing" / "audit.jsonl"
        with self.configured_client(audit=missing_parent), TestClient(server.app) as client:
            with self.assertRaises(WebSocketDisconnect) as raised:
                with client.websocket_connect(
                    "/v2/voice/realtime",
                    headers={"Authorization": "Bearer " + TOKEN},
                ):
                    pass
        self.assertEqual(raised.exception.code, 1013)
        self.assertEqual(raised.exception.reason, "voice audit sink unavailable")

    def test_explicit_compatibility_bridge_accepts_only_missing_credential(self):
        with self.configured_client(bridge=True), TestClient(server.app) as client:
            missing = client.get("/v1/voice/config")
            wrong = client.get(
                "/v1/voice/config",
                headers={"Authorization": "Bearer " + ("x" * 48)},
            )
        self.assertEqual(missing.status_code, 200)
        self.assertEqual(wrong.status_code, 401)

    def test_every_operational_http_voice_route_is_protected(self):
        operational = {
            route.path
            for route in server.app.routes
            if route.path.startswith("/v1/voice/")
        }
        self.assertGreaterEqual(len(operational), 10)
        self.assertTrue(all(server.protected_http_route(path) for path in operational))
        self.assertFalse(server.protected_http_route("/health"))
        self.assertFalse(server.protected_http_route("/v2/voice/capabilities"))


if __name__ == "__main__":
    unittest.main()
