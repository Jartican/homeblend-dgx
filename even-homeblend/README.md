# HomeBlend Voice for Even G2

Private G2 voice client for the existing Exocortex Voice Core v2 on the DGX Spark.
The glasses adapter is intentionally thin: it captures 16 kHz PCM, renders text,
and speaks the transport-neutral Voice Core protocol. STT, routing, tools, and TTS
remain behind the DGX gateway so a different pair of glasses can replace G2 later.

## Current routes

- **HomeBlend Auto** chooses the fast or quality local model.
- **HomeBlend Fast 8B** forces the low-latency local conversation route.
- **HomeBlend Quality 27B** forces the deeper local route.
- Private SearXNG web tools are always enabled in this prototype build.
- Hosted Codex is available separately through Even Terminal. It is not yet a
  Voice Core model option; adding a Codex connector belongs at the gateway, not
  in this glasses client.

## Privacy boundary

```text
G2 microphones -> Even phone WebView -> tailnet-only WSS -> Voice Core v2
  -> in-memory faster-Whisper STT -> HomeBlend -> in-memory Kokoro TTS
```

The DGX gateway reports `raw_audio_persistence: false`. The app stores only the
selected route in phone-origin local storage. It does not
store transcripts, responses, or audio. Tailscale identity/ACLs are the access
boundary; no public tunnel is used. Wake words and generic glasses gestures are
never treated as authorization for sensitive tools.

If the phone grants location permission, the client rounds coordinates to two
decimal places (roughly one kilometre), keeps them only for the running session,
and sends them to the private gateway for location-relative tools. Coordinates
are excluded from the metadata audit log.

## Controls

- Tap while ready: start recording.
- Tap while listening: commit the turn.
- Tap while thinking/speaking: barge in and start a replacement turn.
- Scroll up/down while idle: switch Auto / Fast 8B / Quality 27B.
- Private web search stays enabled across routes and sessions.
- Double-tap: exit through the Even system confirmation.

Replies render on G2 and play through the phone or paired earbuds because G2 has
no speaker.

## Develop and simulate

```powershell
Copy-Item .env.example .env.local
npm install
```

For the Windows simulator, change `.env.local` to the documented loopback URL,
then run these in separate terminals:

```powershell
npm run voice:tunnel
npm run dev
npm run simulate
```

The tunnel terminates on the laptop and forwards only to the DGX loopback voice
gateway. Before packaging for a real Spark, pin its exact MagicDNS hostname in
both the build environment and Even's signed network allowlist:

```powershell
python .\configure-voice-core-host.py <device>.tail<id>.ts.net
```

The committed host is deliberately non-routable. The helper writes the ignored
`.env.local` and updates only the exact host allowlist in `app.json`.

## Build and install

```powershell
npm run build
npm run pack
```

The phone must run Even App 2.2.9 or newer and be connected to the same Tailscale
tailnet as the target Spark. Install the generated `.ehpk` through Even Hub's
normal developer flow.

This G2 prototype does not yet have secure per-install credential provisioning.
Do not keep Voice Core's unauthenticated compatibility bridge enabled for it in
production. Use the signed iPhone companion as the production client until the
G2 package has its own independently revocable credential path.

## Protocol

`src/protocol.ts` mirrors Voice Core v2 protocol version 1. JSON controls remain
device-neutral. Binary audio uses the 24-byte `EXV2` network-order header. G2-only
bridge calls are confined to `src/main.ts`; the gateway and model routing contain
no Even SDK dependency.
