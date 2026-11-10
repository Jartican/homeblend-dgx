# Private assistant storage

This directory contains schema source only. It must not be applied until the
PostgreSQL LUKS migration and backup restore drill pass.

`apply-private-assistant-schema.sh` enforces the host-side encryption check
before applying the migration. Do not bypass that gate. The schema intentionally
stores only a reference to speaker profiles; biometric embeddings remain in the
separate encrypted biometric vault.

The schema does not contain raw-audio or exact-location columns. Private mode
must be enforced before the storage adapter calls PostgreSQL. Non-Private
content initially has indefinite retention (`retention_until IS NULL`). The
`agent_turns` table stores the exact submitted request and final response plus
bounded model/tool provenance, not credentials or raw tool payloads.
