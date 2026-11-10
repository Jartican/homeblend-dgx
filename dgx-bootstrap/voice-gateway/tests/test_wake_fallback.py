import struct
import unittest

from server import pcm_float32_rms, validate_client_source, wake_transcript_matches
from realtime_protocol import ProtocolError


class WakeFallbackTests(unittest.TestCase):
    def test_wake_aliases_match_only_at_the_start(self):
        for transcript in (
            "Gauss",
            "Hey Gauss.",
            "hey, goss can you hear me",
            "Gouse, what is the weather?",
            "Gauze",
        ):
            with self.subTest(transcript=transcript):
                self.assertTrue(wake_transcript_matches(transcript))

        for transcript in (
            "Hey guys",
            "We discussed cause and effect",
            "Gaussian elimination",
            "Please ask Gauss later",
            "",
        ):
            with self.subTest(transcript=transcript):
                self.assertFalse(wake_transcript_matches(transcript))

    def test_pcm_rms_distinguishes_silence_and_speech_energy(self):
        silence = struct.pack("<16f", *([0.0] * 16))
        voiced = struct.pack("<16f", *([0.02, -0.02] * 8))
        self.assertEqual(pcm_float32_rms(silence), 0.0)
        self.assertAlmostEqual(pcm_float32_rms(voiced), 0.02, places=5)
        self.assertEqual(pcm_float32_rms(b"bad"), 0.0)

    def test_client_source_is_bounded_and_machine_readable(self):
        self.assertEqual(validate_client_source("Safari_Phone.Test"), "safari_phone.test")
        self.assertEqual(validate_client_source(None), "unspecified")
        for source in ("contains spaces", "../escape", "", "x" * 65):
            with self.subTest(source=source):
                with self.assertRaises(ProtocolError):
                    validate_client_source(source)


if __name__ == "__main__":
    unittest.main()
