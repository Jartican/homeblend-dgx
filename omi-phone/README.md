# Omi Phone Core

`OmiPhoneCore` is a device-neutral Swift package for the private Omi → phone →
HomeBlend companion. It contains no Omi SDK, Bluetooth, storage, SwiftUI, or
audio-session dependency. Those belong in adapters added by the future iOS
app. Its only concrete I/O adapter is the Voice Core WebSocket transport.

The core currently provides:

- assistant, translation, and private-session state;
- deterministic `Hey Gauss` mode commands;
- a pure event/effect state machine;
- text-first response routing;
- opt-in headphone speech with no phone-speaker fallback;
- separately authorized phone-speaker output; and
- a `URLSessionWebSocketTask` Voice Core v2 adapter with injectable sockets;
- externally supplied, refreshable authorized requests (credentials are not
  stored by the core);
- server-state-gated controls and capture-only PCM transmission; and
- bounded reconnect attempts with no queued audio or replay;
- hardware-free XCTest coverage.

## Integration boundaries

An iOS app should translate external input into `CompanionEvent` values and
perform returned `CompanionEffect` values:

- Omi or phone microphone adapter → transcript events
- HomeBlend transport adapter → agent response events
- SwiftUI adapter → text rendering and user output preferences
- `AVAudioSession` adapter → headphone state and speech playback

The audio adapter must still respect iOS system mute/volume behavior. The core's
`phoneSpeakerEnabledInApp` flag records only the user's explicit app-level
permission; it does not bypass system controls.

The app owns credential retrieval. Supply `VoiceCoreTransport` with an async
request provider that creates a fresh `URLRequest` (including its short-lived
`Authorization: Bearer …` header) for each connection attempt. Do not put a
token in `UserDefaults`, package configuration, or the transport object.

## Tests

When a Swift 5.9+ toolchain is available:

```sh
swift test --package-path omi-phone
```
