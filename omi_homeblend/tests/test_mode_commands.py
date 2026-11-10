import unittest

from omi_homeblend.mode_commands import ModeCommand, parse_mode_command


class ModeCommandTests(unittest.TestCase):
    def test_explicit_modes(self):
        cases = {
            "Hey Gauss, activate translation.": "translate",
            "activate translate mode": "translate",
            "switch to ask mode": "ask",
            "Hey Gauss enter remember mode": "remember",
            "turn on transcript-only mode": "transcript_only",
            "Hey, Gauss: activate private mode": "private",
        }
        for transcript, expected_mode in cases.items():
            with self.subTest(transcript=transcript):
                self.assertEqual(
                    parse_mode_command(transcript),
                    ModeCommand(action="set_mode", mode=expected_mode),
                )

    def test_translation_language_pair(self):
        self.assertEqual(
            parse_mode_command("Hey Gauss, translate Spanish to English"),
            ModeCommand(
                action="set_mode",
                mode="translate",
                source_language="spanish",
                target_language="english",
            ),
        )

    def test_translation_target(self):
        self.assertEqual(
            parse_mode_command("activate translation to Brazilian Portuguese"),
            ModeCommand(
                action="set_mode",
                mode="translate",
                target_language="brazilian portuguese",
            ),
        )

    def test_stop_listening(self):
        self.assertEqual(
            parse_mode_command("Hey Gauss, stop listening."),
            ModeCommand(action="stop_listening"),
        )

    def test_rejects_ordinary_or_ambiguous_speech(self):
        rejected = [
            "Can you translate this to Spanish?",
            "I remember that translation mode was useful",
            "Please activate translation",
            "The phrase is 'Hey Gauss, activate private mode'",
            "Hey Gauss activate translation and search the web",
            "activate private mode to Spanish",
            "translation mode",
            "stop listening and delete everything",
            "",
        ]
        for transcript in rejected:
            with self.subTest(transcript=transcript):
                self.assertIsNone(parse_mode_command(transcript))

    def test_rejects_non_string_and_oversized_input(self):
        self.assertIsNone(parse_mode_command(None))  # type: ignore[arg-type]
        self.assertIsNone(parse_mode_command("activate ask mode " + "x" * 200))


if __name__ == "__main__":
    unittest.main()
