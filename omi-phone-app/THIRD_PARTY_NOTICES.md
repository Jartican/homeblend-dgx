# Third-party notices

## swift-opus

- Upstream: `https://github.com/nelcea/swift-opus.git`
- Pinned revision: `a22f542387f1dd72c6c045ecc3b21dfed71acce2`
- Upstream version: `1.0.0`
- License: BSD 3-Clause
- Purpose: decode Omi's Opus 16 kHz audio frames to in-memory PCM16LE.

The private companion imports only the `Opus` decoder product. It does not
import Omi's SwiftWhisper, AudioKit, cloud transcription, logging, or temporary
WAV-file paths. The pinned package embeds the upstream Opus C source through its
`Sources/Copus` git submodule; that nested source and its license must be
included in the macOS/Xcode dependency and license audit before distribution.

The full BSD 3-Clause text is available in the pinned upstream repository at
`LICENSE` and must accompany binary redistributions as required by that license.
