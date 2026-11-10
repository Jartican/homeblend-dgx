"""Pure speaker-profile math and validation."""
from __future__ import annotations

import math
import re
from collections.abc import Iterable

PROFILE_PATTERN = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")


def validate_profile(profile: str) -> str:
    value = profile.strip().lower()
    if not PROFILE_PATTERN.fullmatch(value):
        raise ValueError("profile must match ^[a-z][a-z0-9_-]{0,31}$")
    return value


def normalize(values: Iterable[float]) -> list[float]:
    vector = [float(value) for value in values]
    magnitude = math.sqrt(sum(value * value for value in vector))
    if not vector or not math.isfinite(magnitude) or magnitude <= 0:
        raise ValueError("speaker embedding is empty or invalid")
    return [value / magnitude for value in vector]


def centroid(embeddings: Iterable[Iterable[float]]) -> list[float]:
    vectors = [normalize(vector) for vector in embeddings]
    if not vectors:
        raise ValueError("at least one embedding is required")
    width = len(vectors[0])
    if any(len(vector) != width for vector in vectors):
        raise ValueError("speaker embeddings have inconsistent dimensions")
    return normalize(sum(vector[index] for vector in vectors) / len(vectors) for index in range(width))


def similarity(first: Iterable[float], second: Iterable[float]) -> float:
    left, right = normalize(first), normalize(second)
    if len(left) != len(right):
        raise ValueError("speaker embeddings have inconsistent dimensions")
    # Match NeMo VerificationMixin's normalized [-1, 1] -> [0, 1] score.
    return (sum(a * b for a, b in zip(left, right, strict=True)) + 1.0) / 2.0
