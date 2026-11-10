"""Verify the pinned phonemizer layout without modifying upstream code.

The current phonemizer creates isolated eSpeak copies. They are required for
correct process behavior but consume temporary storage over a long container
lifetime. Exocortex bounds that lifetime with the Speaches request limit in
compose.voice.yaml instead of patching upstream interpreter code.
"""
from pathlib import Path


path = Path(
    "/home/ubuntu/speaches/.venv/lib/python3.12/site-packages/"
    "phonemizer/backend/espeak/api.py"
)
source = path.read_text(encoding="utf-8")
expected = (
    "self._tempdir = tempfile.mkdtemp()",
    "shutil.copy(library_path, espeak_copy, follow_symlinks=False)",
)
if any(value not in source for value in expected):
    raise SystemExit("unexpected phonemizer EspeakAPI source; review the pinned image")
