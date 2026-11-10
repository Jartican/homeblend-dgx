import sys
import unittest
import hashlib
import json
import tempfile
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from realtime_auth import (
    AuthFailureMonitor,
    ClientAccessController,
    RealtimeAuthConfigurationError,
    authorize_client,
    extract_bearer_token,
    extract_websocket_token,
    is_authorized,
    require_configured_token_hashes,
    selected_websocket_subprotocol,
)


TOKEN = "a" * 48
TOKEN_HASH = hashlib.sha256(TOKEN.encode("utf-8")).hexdigest()


class RealtimeAuthTests(unittest.TestCase):
    def write_registry(self, clients):
        temporary = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent)
        path = Path(temporary.name) / "clients.json"
        path.write_text(json.dumps({"schema_version": 1, "clients": clients}), encoding="utf-8")
        self.addCleanup(temporary.cleanup)
        return path

    def registry_client(self, **overrides):
        client = {
            "client_id": "iphone-primary",
            "credential_id": "iphone-primary-2026-10",
            "token_sha256": TOKEN_HASH,
            "created_at": "2026-10-01T00:00:00Z",
            "expires_at": "2027-10-01T00:00:00Z",
            "enabled": True,
            "max_connections": 2,
            "max_requests_per_minute": 2,
            "max_session_seconds": 3600,
        }
        client.update(overrides)
        return client

    def test_configuration_fails_closed(self):
        for value in (None, "", "short", " " * 64, "ab" * 31):
            with self.subTest(value=value), self.assertRaises(RealtimeAuthConfigurationError):
                require_configured_token_hashes(value)

    def test_configuration_accepts_multiple_sha256_hashes(self):
        values = require_configured_token_hashes(f"{TOKEN_HASH},{'b' * 64}")
        self.assertEqual(len(values), 2)
        self.assertTrue(all(len(value) == 32 for value in values))

    def test_extracts_only_bearer_authorization(self):
        self.assertEqual(extract_bearer_token({"authorization": f"Bearer {TOKEN}"}), TOKEN)
        self.assertEqual(extract_bearer_token({"Authorization": f"bearer {TOKEN}"}), TOKEN)
        for value in ("", TOKEN, f"Basic {TOKEN}", "Bearer "):
            with self.subTest(value=value):
                self.assertIsNone(extract_bearer_token({"authorization": value}))

    def test_authorization_requires_exact_token(self):
        self.assertTrue(is_authorized({"authorization": f"Bearer {TOKEN}"}, TOKEN_HASH))
        self.assertFalse(is_authorized({}, TOKEN_HASH))
        self.assertFalse(is_authorized({"authorization": f"Bearer {TOKEN}x"}, TOKEN_HASH))
        self.assertFalse(is_authorized({"authorization": "Bearer short"}, TOKEN_HASH))

    def test_temporary_loopback_proxy_compatibility_requires_explicit_flag(self):
        with self.assertRaises(RealtimeAuthConfigurationError):
            is_authorized({}, "")
        self.assertTrue(is_authorized(
            {}, "", allow_unconfigured_loopback_proxy=True
        ))
        self.assertFalse(is_authorized(
            {}, TOKEN_HASH, allow_unconfigured_loopback_proxy=True
        ))

    def test_browser_websocket_subprotocol_authentication(self):
        headers = {"sec-websocket-protocol": f"homeblend.voice.v1, auth.{TOKEN}"}
        self.assertEqual(extract_websocket_token(headers), TOKEN)
        self.assertEqual(selected_websocket_subprotocol(headers), "homeblend.voice.v1")
        self.assertTrue(is_authorized(headers, TOKEN_HASH))

    def test_websocket_auth_rejects_ambiguous_or_unsafe_credentials(self):
        invalid = [
            f"auth.{TOKEN}",
            "homeblend.voice.v1",
            f"homeblend.voice.v1, auth.{TOKEN}, auth.{TOKEN}",
            "homeblend.voice.v1, auth.not/valid",
        ]
        for value in invalid:
            with self.subTest(value=value):
                headers = {"sec-websocket-protocol": value}
                self.assertIsNone(extract_websocket_token(headers))
                self.assertFalse(is_authorized(headers, TOKEN_HASH))

    def test_registry_authorizes_and_identifies_one_client(self):
        path = self.write_registry([self.registry_client()])
        decision = authorize_client(
            {"authorization": f"Bearer {TOKEN}"},
            registry_path=str(path),
            now=datetime(2026, 10, 28, tzinfo=timezone.utc),
        )
        self.assertTrue(decision.authorized)
        self.assertEqual(decision.reason, "authorized")
        self.assertEqual(decision.client.client_id, "iphone-primary")
        self.assertEqual(decision.client.credential_id, "iphone-primary-2026-10")

    def test_registry_fails_closed_for_missing_wrong_disabled_and_expired_tokens(self):
        cases = [
            ({}, self.registry_client(), "missing_credential"),
            ({"authorization": f"Bearer {'z' * 48}"}, self.registry_client(), "invalid_credential"),
            ({"authorization": f"Bearer {TOKEN}"}, self.registry_client(enabled=False), "disabled_credential"),
            (
                {"authorization": f"Bearer {TOKEN}"},
                self.registry_client(expires_at="2026-10-27T00:00:00Z"),
                "expired_credential",
            ),
        ]
        for headers, client, reason in cases:
            with self.subTest(reason=reason):
                path = self.write_registry([client])
                decision = authorize_client(
                    headers, registry_path=str(path),
                    now=datetime(2026, 10, 28, tzinfo=timezone.utc),
                )
                self.assertFalse(decision.authorized)
                self.assertEqual(decision.reason, reason)

    def test_registry_rejects_duplicate_identity_and_invalid_lifetime(self):
        duplicate = self.registry_client(client_id="iphone-secondary")
        for clients in (
            [self.registry_client(), duplicate],
            [self.registry_client(expires_at="2026-09-01T00:00:00Z")],
        ):
            with self.subTest(clients=clients):
                path = self.write_registry(clients)
                with self.assertRaises(RealtimeAuthConfigurationError):
                    authorize_client(
                        {"authorization": f"Bearer {TOKEN}"}, registry_path=str(path)
                    )

    def test_registry_allows_only_missing_credentials_through_migration_bridge(self):
        path = self.write_registry([self.registry_client()])
        bridge = authorize_client(
            {}, registry_path=str(path), configured_hashes=TOKEN_HASH,
            allow_unconfigured_loopback_proxy=True,
        )
        self.assertTrue(bridge.authorized)
        self.assertTrue(bridge.compatibility_bridge)
        wrong_token = authorize_client(
            {"authorization": f"Bearer {'z' * 48}"},
            registry_path=str(path), configured_hashes=TOKEN_HASH,
            allow_unconfigured_loopback_proxy=True,
        )
        self.assertFalse(wrong_token.authorized)
        self.assertEqual(wrong_token.reason, "invalid_credential")

    def test_client_limits_connections_and_requests(self):
        path = self.write_registry([self.registry_client(max_connections=1)])
        client = authorize_client(
            {"authorization": f"Bearer {TOKEN}"}, registry_path=str(path),
            now=datetime(2026, 10, 28, tzinfo=timezone.utc),
        ).client
        controller = ClientAccessController()
        self.assertTrue(controller.try_open(client))
        self.assertFalse(controller.try_open(client))
        controller.close(client)
        self.assertTrue(controller.try_open(client))
        self.assertTrue(controller.allow_request(client, now=100.0))
        self.assertTrue(controller.allow_request(client, now=101.0))
        self.assertFalse(controller.allow_request(client, now=102.0))
        self.assertTrue(controller.allow_request(client, now=161.1))

    def test_auth_failure_alerts_are_thresholded_windowed_and_rate_limited(self):
        monitor = AuthFailureMonitor(
            threshold=3, window_seconds=10.0, alert_cooldown_seconds=20.0
        )
        self.assertIsNone(monitor.record_failure(now=1.0))
        self.assertIsNone(monitor.record_failure(now=2.0))
        self.assertEqual(monitor.record_failure(now=3.0), 3)
        self.assertIsNone(monitor.record_failure(now=4.0))
        # Old failures age out, and the cooldown must also elapse.
        self.assertIsNone(monitor.record_failure(now=24.0))
        self.assertIsNone(monitor.record_failure(now=25.0))
        self.assertEqual(monitor.record_failure(now=26.0), 3)


if __name__ == "__main__":
    unittest.main()
