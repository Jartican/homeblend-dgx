import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from core import centroid, normalize, similarity, validate_profile


class SpeakerCoreTests(unittest.TestCase):
    def test_profile_names_are_bounded(self):
        self.assertEqual(validate_profile(" Owner "), "owner")
        for invalid in ("", "1owner", "../owner", "owner/name", "a" * 33):
            with self.assertRaises(ValueError):
                validate_profile(invalid)

    def test_normalization_and_similarity(self):
        self.assertEqual(normalize([3, 4]), [0.6, 0.8])
        self.assertAlmostEqual(similarity([1, 0], [1, 0]), 1.0)
        self.assertAlmostEqual(similarity([1, 0], [-1, 0]), 0.0)

    def test_centroid_is_normalized(self):
        self.assertAlmostEqual(sum(value * value for value in centroid([[1, 0], [0, 1]])), 1.0)


if __name__ == "__main__":
    unittest.main()
