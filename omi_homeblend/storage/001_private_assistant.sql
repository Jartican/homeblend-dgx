BEGIN;

CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA IF NOT EXISTS homeblend_voice;

CREATE TABLE IF NOT EXISTS homeblend_voice.conversations (
    id uuid PRIMARY KEY,
    source text NOT NULL CHECK (
        source IN ('omi', 'phone_microphone', 'safari_phone_test', 'share_extension', 'browser_extension', 'import')
    ),
    source_application text,
    mode text NOT NULL CHECK (mode IN ('ask', 'translate', 'remember', 'transcript_only')),
    started_at timestamptz NOT NULL,
    ended_at timestamptz,
    source_language text,
    target_language text,
    retention_until timestamptz,
    consent_scope text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (ended_at IS NULL OR ended_at >= started_at)
);

CREATE TABLE IF NOT EXISTS homeblend_voice.people (
    id uuid PRIMARY KEY,
    display_name text NOT NULL,
    consent_status text NOT NULL CHECK (consent_status IN ('owner', 'explicit', 'revoked')),
    consented_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (consent_status <> 'explicit' OR consented_at IS NOT NULL),
    CHECK (consent_status <> 'revoked' OR revoked_at IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS homeblend_voice.speaker_profile_refs (
    id uuid PRIMARY KEY,
    person_id uuid NOT NULL REFERENCES homeblend_voice.people(id) ON DELETE CASCADE,
    vault_reference text NOT NULL UNIQUE,
    model_name text NOT NULL,
    threshold double precision NOT NULL CHECK (threshold > 0 AND threshold <= 1),
    enrolled_at timestamptz NOT NULL,
    revoked_at timestamptz
);

CREATE TABLE IF NOT EXISTS homeblend_voice.transcript_segments (
    id uuid PRIMARY KEY,
    conversation_id uuid NOT NULL REFERENCES homeblend_voice.conversations(id) ON DELETE CASCADE,
    sequence_no integer NOT NULL CHECK (sequence_no >= 0),
    started_ms integer NOT NULL CHECK (started_ms >= 0),
    ended_ms integer NOT NULL CHECK (ended_ms >= started_ms),
    text text NOT NULL,
    detected_language text,
    translated_text text,
    speaker_cluster text,
    speaker_classification text NOT NULL DEFAULT 'not_evaluated' CHECK (
        speaker_classification IN ('authorized_speaker', 'unknown_voice', 'not_evaluated')
    ),
    attributed_person_id uuid REFERENCES homeblend_voice.people(id) ON DELETE SET NULL,
    attribution_confidence double precision CHECK (
        attribution_confidence IS NULL OR
        (attribution_confidence >= 0 AND attribution_confidence <= 1)
    ),
    attribution_source text CHECK (
        attribution_source IS NULL OR
        attribution_source IN ('owner_model', 'consented_model', 'manual')
    ),
    stt_model text NOT NULL,
    is_final boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (conversation_id, sequence_no),
    CHECK (
        attributed_person_id IS NULL OR
        (attribution_confidence IS NOT NULL AND attribution_source IS NOT NULL)
    )
);

CREATE TABLE IF NOT EXISTS homeblend_voice.memories (
    id uuid PRIMARY KEY,
    conversation_id uuid NOT NULL REFERENCES homeblend_voice.conversations(id) ON DELETE CASCADE,
    source_segment_id uuid REFERENCES homeblend_voice.transcript_segments(id) ON DELETE CASCADE,
    content text NOT NULL,
    embedding vector,
    embedding_model text,
    status text NOT NULL DEFAULT 'candidate' CHECK (status IN ('candidate', 'approved', 'rejected')),
    created_at timestamptz NOT NULL DEFAULT now(),
    reviewed_at timestamptz,
    CHECK ((embedding IS NULL) = (embedding_model IS NULL))
);

CREATE TABLE IF NOT EXISTS homeblend_voice.agent_turns (
    id uuid PRIMARY KEY,
    conversation_id uuid NOT NULL REFERENCES homeblend_voice.conversations(id) ON DELETE CASCADE,
    request_segment_id uuid REFERENCES homeblend_voice.transcript_segments(id) ON DELETE SET NULL,
    sequence_no integer NOT NULL CHECK (sequence_no >= 0),
    requested_at timestamptz NOT NULL,
    completed_at timestamptz,
    request_text text NOT NULL,
    response_text text,
    model_name text NOT NULL,
    tool_profile text NOT NULL,
    tool_provenance jsonb NOT NULL DEFAULT '[]'::jsonb,
    status text NOT NULL CHECK (status IN ('succeeded', 'failed', 'cancelled')),
    error_class text,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (conversation_id, sequence_no),
    CHECK (completed_at IS NULL OR completed_at >= requested_at),
    CHECK (status <> 'succeeded' OR response_text IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS homeblend_voice.action_items (
    id uuid PRIMARY KEY,
    conversation_id uuid NOT NULL REFERENCES homeblend_voice.conversations(id) ON DELETE CASCADE,
    source_segment_id uuid REFERENCES homeblend_voice.transcript_segments(id) ON DELETE CASCADE,
    description text NOT NULL,
    status text NOT NULL DEFAULT 'candidate' CHECK (status IN ('candidate', 'approved', 'dismissed')),
    created_at timestamptz NOT NULL DEFAULT now(),
    reviewed_at timestamptz
);

CREATE INDEX IF NOT EXISTS transcript_segments_conversation_time_idx
    ON homeblend_voice.transcript_segments (conversation_id, sequence_no);
CREATE INDEX IF NOT EXISTS memories_conversation_idx
    ON homeblend_voice.memories (conversation_id);
CREATE INDEX IF NOT EXISTS agent_turns_conversation_time_idx
    ON homeblend_voice.agent_turns (conversation_id, sequence_no);
CREATE INDEX IF NOT EXISTS conversations_retention_idx
    ON homeblend_voice.conversations (retention_until)
    WHERE retention_until IS NOT NULL;

COMMENT ON SCHEMA homeblend_voice IS
    'Private wearable-assistant data. Deploy only after encrypted-at-rest and restore gates pass.';
COMMENT ON TABLE homeblend_voice.speaker_profile_refs IS
    'References encrypted biometric-vault records; never stores voiceprints or embeddings here.';
COMMENT ON COLUMN homeblend_voice.transcript_segments.speaker_classification IS
    'Coarse model label only; authorized_speaker is not authentication or tool authorization.';
COMMENT ON COLUMN homeblend_voice.memories.embedding IS
    'Sensitive derived data covered by conversation retention and deletion policy.';
COMMENT ON TABLE homeblend_voice.agent_turns IS
    'Exact submitted request and final HomeBlend response for encrypted personal retrieval; raw audio, credentials, exact location, and raw tool payloads are excluded.';

COMMIT;
