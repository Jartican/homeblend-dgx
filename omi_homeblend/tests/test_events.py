import json
import unittest

from omi_homeblend.events import (
    ASSISTANT_RESPONSE_FINAL,
    ASSISTANT_RESPONSE_PARTIAL,
    ERROR,
    MODE_CHANGED,
    STATUS,
    TRANSCRIPT_FINAL,
    TRANSCRIPT_PARTIAL,
    Event,
    EventValidationError,
    event_from_dict,
    parse_event,
)


class EventTests(unittest.TestCase):
    def test_all_version_one_event_types(self):
        cases = {
            TRANSCRIPT_PARTIAL: {"text": "hel"},
            TRANSCRIPT_FINAL: {"text": "hello"},
            ASSISTANT_RESPONSE_PARTIAL: {"text": "Hi"},
            ASSISTANT_RESPONSE_FINAL: {"text": "Hi there."},
            MODE_CHANGED: {"mode": "translate"},
            STATUS: {"status": "ready"},
            ERROR: {"code": "upstream_unavailable", "message": "Try again"},
        }
        for event_type, payload in cases.items():
            with self.subTest(event_type=event_type):
                event = Event(type=event_type, payload=payload)
                self.assertEqual(event.version, 1)
                self.assertEqual(dict(event.payload), payload)
                self.assertEqual(parse_event(event.to_json()), event)

    def test_wire_format_round_trip(self):
        event = parse_event(
            '{"version":1,"type":"transcript_final",'
            '"payload":{"text":"¿Listo?"}}'
        )
        wire = json.loads(event.to_json())
        self.assertEqual(
            wire,
            {
                "version": 1,
                "type": "transcript_final",
                "payload": {"text": "¿Listo?"},
            },
        )

    def test_payload_is_defensively_copied_and_read_only(self):
        payload = {"text": "original"}
        event = Event(type=TRANSCRIPT_FINAL, payload=payload)
        payload["text"] = "changed"
        self.assertEqual(event.payload["text"], "original")
        with self.assertRaises(TypeError):
            event.payload["text"] = "changed"  # type: ignore[index]

    def test_rejects_unknown_type_and_version(self):
        invalid = [
            {"version": 2, "type": STATUS, "payload": {"status": "ready"}},
            {"version": "1", "type": STATUS, "payload": {"status": "ready"}},
            {"version": 1.0, "type": STATUS, "payload": {"status": "ready"}},
            {"version": True, "type": STATUS, "payload": {"status": "ready"}},
            {"version": 1, "type": "transcript", "payload": {"text": "hi"}},
        ]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(EventValidationError):
                event_from_dict(value)

    def test_rejects_missing_extra_and_irrelevant_fields(self):
        invalid = [
            {"version": 1, "type": STATUS},
            {
                "version": 1,
                "type": STATUS,
                "payload": {"status": "ready"},
                "device": "phone",
            },
            {"version": 1, "type": ERROR, "payload": {"code": "failed"}},
            {
                "version": 1,
                "type": MODE_CHANGED,
                "payload": {"mode": "ask", "text": "irrelevant"},
            },
        ]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(EventValidationError):
                event_from_dict(value)

    def test_private_or_device_specific_fields_have_no_wire_slot(self):
        private_fields = {
            "audio": "pcm-data",
            "secret": "token",
            "location": {"latitude": 1.0, "longitude": 2.0},
            "voiceprint": "embedding",
        }
        for field, value in private_fields.items():
            with self.subTest(field=field), self.assertRaises(EventValidationError):
                event_from_dict(
                    {
                        "version": 1,
                        "type": TRANSCRIPT_FINAL,
                        "payload": {"text": "hello", field: value},
                    }
                )

    def test_rejects_wrong_shapes_and_field_types(self):
        invalid = [
            [],
            {1: "not a JSON field"},
            {"version": 1, "type": STATUS, "payload": "ready"},
            {"version": 1, "type": STATUS, "payload": {"status": "ready", 1: "x"}},
            {"version": 1, "type": STATUS, "payload": {"status": 200}},
            {"version": 1, "type": ERROR, "payload": {"code": "x", "message": None}},
        ]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(EventValidationError):
                event_from_dict(value)

    def test_rejects_invalid_json_duplicate_keys_and_non_text(self):
        invalid_json = [
            "",
            "[]",
            '{"version":1,"version":1,"type":"status",'
            '"payload":{"status":"ready"}}',
            '{"version":NaN,"type":"status","payload":{"status":"ready"}}',
            '{"version":1,"type":"status","payload":{"status":"ready"}} trailing',
        ]
        for raw in invalid_json:
            with self.subTest(raw=raw), self.assertRaises(EventValidationError):
                parse_event(raw)
        with self.assertRaises(EventValidationError):
            parse_event(b"{}")  # type: ignore[arg-type]
        with self.assertRaises(EventValidationError):
            parse_event('"\ud800"')


if __name__ == "__main__":
    unittest.main()
