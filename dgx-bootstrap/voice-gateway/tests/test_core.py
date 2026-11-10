import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from core import authorize_speaker, extract_answer, extract_transcript, parse_history, security_state, select_model, validate_options, validate_voice_mode


class CoreTests(unittest.TestCase):
    def test_validation_accepts_supported_options(self):
        self.assertEqual(validate_options("AUTO", 2, "web"), ("auto", 2, "web"))

    def test_validation_rejects_unknown_or_out_of_range_options(self):
        for values in (("large", 1, "none"), ("auto", 0, "none"), ("auto", 1, "repo")):
            with self.subTest(values=values), self.assertRaises(ValueError):
                validate_options(*values)

    def test_auto_routes_routine_short_text_to_8b(self):
        self.assertEqual(select_model("What time is the meeting?"), "exocortex-chat-fast")

    def test_auto_routes_effort_length_and_complexity_to_27b(self):
        self.assertEqual(select_model("hello", effort=3), "exocortex-agent-quality")
        self.assertEqual(select_model("x" * 600), "exocortex-agent-quality")
        self.assertEqual(select_model("Please debug this behavior"), "exocortex-agent-quality")

    def test_explicit_model_overrides_auto_policy(self):
        self.assertEqual(select_model("debug architecture", "8b", 5), "exocortex-chat-fast")
        self.assertEqual(select_model("hi", "27b", 1), "exocortex-agent-quality")

    def test_extracts_valid_upstream_responses(self):
        self.assertEqual(extract_transcript({"text": " hello "}), "hello")
        payload = {"output": [{"type": "message", "content": [{"type": "output_text", "text": " answer "}]}]}
        self.assertEqual(extract_answer(payload), "answer")

    def test_rejects_invalid_upstream_responses(self):
        for function, payload in ((extract_transcript, {}), (extract_answer, {"output": []})):
            with self.subTest(function=function.__name__), self.assertRaises(ValueError):
                function(payload)

    def test_security_hooks_are_disabled_and_independent(self):
        state = security_state()
        self.assertEqual(state["wake_word"]["status"], "not_evaluated")
        self.assertFalse(state["voice_auth"]["trusted"])
        state["wake_word"]["enabled"] = True
        self.assertFalse(state["voice_auth"]["enabled"])

    def test_personal_mode_rejects_unverified_background_speakers(self):
        self.assertFalse(authorize_speaker("personal", owner_verified=False)["accepted"])
        self.assertTrue(authorize_speaker("personal", owner_verified=True)["accepted"])

    def test_conversation_mode_requires_owner_arming(self):
        self.assertFalse(authorize_speaker("conversation", owner_verified=True)["accepted"])
        decision = authorize_speaker("conversation", owner_verified=False, session_armed_by_owner=True)
        self.assertTrue(decision["accepted"])
        self.assertEqual(decision["reason"], "owner_armed_open_conversation")

    def test_transcript_mode_requires_arming_and_consent(self):
        self.assertFalse(authorize_speaker("transcript", owner_verified=True, session_armed_by_owner=True)["accepted"])
        self.assertTrue(authorize_speaker(
            "transcript", owner_verified=False, session_armed_by_owner=True, recording_consent=True
        )["accepted"])
        with self.assertRaises(ValueError):
            validate_voice_mode("always-listen")

    def test_history_is_bounded_and_role_limited(self):
        self.assertEqual(
            parse_history('[{"role":"user","content":" hi "}]'),
            [{"role": "user", "content": "hi"}],
        )
        for raw in ('not-json', '[{"role":"system","content":"unsafe"}]', '[]' * 20):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                parse_history(raw)


if __name__ == "__main__":
    unittest.main()
