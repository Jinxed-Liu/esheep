PRAGMA foreign_keys = ON;

CREATE TABLE accounts (
    id TEXT PRIMARY KEY,
    apple_subject_hash TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'deleting', 'deleted', 'locked')),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE apple_credentials (
    account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    encrypted_refresh_token TEXT NOT NULL,
    encryption_iv TEXT NOT NULL,
    apple_user_hash TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    refresh_token_hash TEXT NOT NULL UNIQUE,
    expires_at INTEGER NOT NULL,
    revoked_at INTEGER,
    created_at INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL
);

CREATE INDEX sessions_account_idx ON sessions(account_id, expires_at);

CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    public_key_jwk TEXT NOT NULL,
    display_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
    created_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    UNIQUE(account_id, id)
);

CREATE TABLE farm_directories (
    id TEXT PRIMARY KEY,
    owner_account_id TEXT NOT NULL REFERENCES accounts(id),
    cloud_zone_name TEXT NOT NULL,
    share_record_name TEXT,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'deleting', 'deleted')),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE memberships (
    id TEXT PRIMARY KEY,
    farm_id TEXT NOT NULL REFERENCES farm_directories(id) ON DELETE CASCADE,
    account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('owner', 'administrator', 'worker')),
    status TEXT NOT NULL CHECK (status IN ('pending', 'active', 'revoked')),
    share_participant_record_name TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE(farm_id, account_id)
);

CREATE INDEX memberships_account_idx ON memberships(account_id, status);

CREATE TABLE invites (
    id TEXT PRIMARY KEY,
    farm_id TEXT NOT NULL REFERENCES farm_directories(id) ON DELETE CASCADE,
    created_by_account_id TEXT NOT NULL REFERENCES accounts(id),
    role TEXT NOT NULL CHECK (role IN ('administrator', 'worker')),
    code_hash TEXT NOT NULL UNIQUE,
    expires_at INTEGER NOT NULL,
    redeemed_by_account_id TEXT REFERENCES accounts(id),
    redeemed_at INTEGER,
    confirmed_at INTEGER,
    used_at INTEGER,
    created_at INTEGER NOT NULL
);

CREATE TABLE capability_certificates (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    farm_id TEXT NOT NULL REFERENCES farm_directories(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    capabilities_json TEXT NOT NULL,
    certificate_jws TEXT NOT NULL,
    issued_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    revoked_at INTEGER
);

CREATE INDEX capabilities_lookup_idx ON capability_certificates(account_id, farm_id, device_id, expires_at);

CREATE TABLE deletion_jobs (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    status TEXT NOT NULL CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    error_code TEXT,
    created_at INTEGER NOT NULL,
    completed_at INTEGER
);

CREATE TABLE security_audit_events (
    id TEXT PRIMARY KEY,
    account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL,
    farm_id TEXT REFERENCES farm_directories(id) ON DELETE SET NULL,
    event_type TEXT NOT NULL,
    fingerprint TEXT UNIQUE,
    detail_json TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE INDEX security_events_actor_idx ON security_audit_events(account_id, event_type, created_at);
