# Omi/HomeBlend Privacy, Retention, and Threat Model

Status: owner-approved baseline; retention remains owner-configurable
Date: 2026-10-24

## Non-negotiable defaults

- Raw audio is never persisted by the phone, Voice Core, PostgreSQL, logs, or
  backups. Bounded in-memory audio buffers are erased when consumed or when a
  session ends.
- Private mode persists no transcript, response, tool content, exact location,
  memory, embedding, or voiceprint reference.
- No transcript-derived data is written until encrypted PostgreSQL and encrypted
  backup restore gates pass.
- Speaker recognition is advisory, never authentication.
- A wake phrase changes interaction state; it never authorizes a sensitive tool.
- Logs contain identifiers, timings, result classes, and coarse error codes—not
  utterances, responses, coordinates, credentials, or biometric vectors.

## Owner-selected retention policy

Content is retained indefinitely for the initial personal-memory phase. In the
schema, `retention_until IS NULL` means no scheduled expiry. The phone app must
still provide explicit deletion and export controls. Private mode remains the
intentional no-storage escape hatch.

| Mode/data | Default | Notes |
|---|---:|---|
| Ask transcript and request/response | Indefinite | Includes submitted request, final response, model and tool provenance |
| Translation transcript and output | Indefinite | Requires visible active-mode indicator |
| Remember transcript | Indefinite | Explicit recording/consent state required |
| Transcript-only | Indefinite | No memory extraction |
| Private | Never | No persistence override |
| Derived memories/action candidates | Indefinite | Owner can delete or change policy later |
| Operational metadata | Indefinite | Never contains content or precise location |
| Raw audio | Never | In-memory processing only |

Future retention changes affect new data immediately and may schedule older
eligible data for deletion. Increasing retention never resurrects deleted data.

Persisted agent turns contain the exact text submitted to HomeBlend and the
final text response, linked to source transcript segments. They also retain the
selected model, status, timing, and bounded tool provenance. Raw tool payloads,
credentials, precise coordinates, raw audio, and biometric scores are excluded.

## Recording and consent indicators

- `Ask`: neutral listening indicator while the current request is buffered.
- `Translate`: translation indicator; persistence-off badge by default.
- `Remember` and `Transcript only`: persistent, high-visibility recording
  indicator in the phone UI and periodic haptic reminder.
- `Private`: distinct privacy indicator and explicit `Not saved` confirmation.
- Multi-speaker transcription requires an in-app opt-in for the current
  conversation. Persistent enrollment of anyone other than the owner requires
  explicit consent and multiple clean samples.
- Loss of phone/DGX connectivity changes the indicator to `Not connected`; the
  app must not imply that capture or storage succeeded.

## Tool policy

| Mode | Default tool capability |
|---|---|
| Ask | Read-only web, weather, market data, and approved personal retrieval |
| Translate | Translation only; no web or personal tools |
| Remember | Post-session memory/action candidates; no automatic external action |
| Transcript only | No agent tools |
| Private | Approved read-only tools, with no persistence of content |

Any side-effecting tool—messages, purchases, calendar writes, device control,
file changes, or account changes—requires an explicit confirmation in the phone
UI. Voice alone is insufficient for high-impact authorization.

## Deletion semantics

Deleting a conversation cascades to its transcript segments, memories, action
items, and embeddings. Person deletion removes attribution and the associated
encrypted biometric-vault profile. Corrections preserve source transcript text
and update attribution separately.

Deletion is immediate from the live database and search indexes. Encrypted
backups age out on their documented schedule; the system records a tombstone ID
outside content backups so restored data is re-deleted before use. SSD secure
deletion is not guaranteed, which is why the database, backups, and biometric
vault must be encrypted from the beginning.

## Threats and controls

### Lost or stolen pendant

Threats: onboard buffered audio, unauthorized reconnection, device identifiers.

Controls: disable or clear the documented onboard raw-audio ring; require a
paired phone; expose a revoke-device action; avoid storing secrets on the
pendant; show last-seen state. Until the ring is proven safe, treat loss as a
possible audio disclosure.

### Lost or stolen phone

Threats: visible transcripts, active sessions, cached credentials.

Controls: iOS Data Protection/Keychain, biometric/passcode app lock, minimal
cache, remote device revocation, short-lived DGX credentials, no plaintext
exports, and no notification previews containing transcript text by default.

### Stolen DGX disk or backup

Threats: transcripts, memories, embeddings, database credentials, backups.

Controls: LUKS2 PostgreSQL storage, encrypted off-device backups, separate
encrypted biometric vault, keys stored off-host, restore drills, and no
plaintext fallback after migration.

### Compromised tailnet identity

Threats: connection to Voice Core, replay, unauthorized queries.

Controls: per-client application authentication in addition to Tailscale,
short-lived/revocable credentials, WSS, server-side authorization, bounded
message sizes, session nonces, rate limiting, and audit metadata. Tailnet
membership alone is not sufficient authorization.

### Malicious or replayed audio

Threats: prompt injection through speech, false wake, replayed owner voice,
unauthorized tools.

Controls: wake word is not authorization; speaker match is not authentication;
strict deterministic mode commands; treat transcript content as untrusted;
require UI confirmation for side effects; label retrieved/tool content;
rate-limit wake attempts; support immediate stop/cancel.

### Compromised phone app or dependency

Threats: audio/transcript exfiltration and secret theft.

Controls: minimal dependencies, pinned versions, dependency review, no Omi cloud
SDK path in private sessions, network allowlist limited to the DGX endpoint, and
App Store/TestFlight build provenance before routine use.

### Running unlocked DGX compromise

Threats: LUKS does not protect data after unlock.

Controls: least-privilege database role, container/service isolation, patching,
host firewall, no public Voice Core exposure, restricted admin access, and
content-free audit alerts.

## Release gates

- Storage and backups pass encryption and restore checks.
- Phone app demonstrates no-speaker fallback and no-content logging.
- Private and translation-no-persist modes are verified with database queries.
- Lost-device revocation and expired credentials are tested.
- Omi onboard storage behavior is verified or mitigated.
- A tabletop exercise covers stolen phone, stolen disk, tailnet compromise, and
  malicious audio.
