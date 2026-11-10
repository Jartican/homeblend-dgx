# HomeBlend iPhone companion shell

This directory contains the native SwiftUI shell for the private Omi/HomeBlend
companion. It provides the privacy/configuration boundary plus the first live
phone-to-DGX path:

- text is the default response output;
- optional headphone speech has no phone-speaker fallback;
- phone-speaker output requires an explicit in-app toggle;
- location sharing begins off;
- the Voice Core bearer credential is stored in the device-only Keychain;
- authorized WebSocket requests target the tailnet-only `wss://` endpoint;
- Voice Core partial/final transcripts and responses reduce into live UI state;
- microphone PCM is converted in memory to 16 kHz mono PCM16LE and sent only
  while the server reports a capturing session;
- no transcript, response, token, or raw audio is logged or persisted.

The first BLE/Omi adapter is present and the UI can select phone or pendant
capture. Omi discovery, codec negotiation, fragmentation, PCM/mu-law fallback,
and pinned Opus decoding are implemented, but still require real pendant
qualification. Audio playback, live location acquisition, and physical-device
qualification remain pending. Full AVFoundation/CoreBluetooth type-checking,
dependency resolution, signing, and runtime testing require macOS/Xcode and a
physical iPhone.

## Prerequisites

- macOS with a current Xcode installation
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- an Apple Development identity and selected Development Team
- Tailscale installed and connected on the iPhone
- access to the HomeBlend tailnet service

XcodeGen resolves `swift-opus` at the exact revision recorded in `project.yml`.
See `THIRD_PARTY_NOTICES.md`; do not change it to an unpinned version range.

## Generate and build

From this directory on the Mac:

```sh
python3 configure-voice-core-host.py spark-example.tail-example.ts.net
xcodegen generate
open HomeBlendCompanion.xcodeproj
```

Use the exact HTTPS hostname reported by `tailscale serve status` on the new
DGX. The hostname is compiled into the signed app and the request policy pins
credentials to that one host; the app deliberately does not trust a wildcard
tailnet suffix or an editable runtime URL.

Xcode resolves the local Swift package at `../omi-phone`. Select the
`HomeBlendCompanion` target, choose your Development Team under Signing &
Capabilities, replace the bundle identifier if necessary, and build to an iOS
16 or later phone. A physical device is required for meaningful Bluetooth,
background-audio, Keychain, and tailnet testing.

The generated `.xcodeproj` should not be hand-edited or committed. Change
`project.yml` and regenerate it instead.

## Credential behavior

Enter only the token value (without the `Bearer` prefix). The app stores it as
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: it cannot synchronize to
iCloud and is unavailable after reboot until the phone has been unlocked once.
The UI never reads the saved value back into a text field.

The request factory creates a fresh request to the exact host pinned in
`project.yml`, for example:

```text
wss://spark-example.tail-example.ts.net/voice/v2/voice/realtime
```

and rejects non-`wss` endpoints. It adds the credential only as an
`Authorization: Bearer …` header and requests no-store caching.

## Signing note

`DEVELOPMENT_TEAM` is intentionally blank because signing identities are
machine- and account-specific. Background audio and Bluetooth declarations do
not grant permission by themselves; iOS still controls runtime access, and App
Store distribution may require explaining these background capabilities during
review.
