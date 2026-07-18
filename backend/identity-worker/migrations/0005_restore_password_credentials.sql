-- Cross-platform account credentials. Passwords are never stored in plaintext:
-- password_hash is PBKDF2-SHA256 with a per-account random salt.
CREATE TABLE IF NOT EXISTS password_credentials (
    account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
    username_normalized TEXT NOT NULL UNIQUE,
    password_salt TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    password_iterations INTEGER NOT NULL,
    failed_attempts INTEGER NOT NULL DEFAULT 0,
    locked_until INTEGER,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS password_credentials_username_idx
ON password_credentials(username_normalized);
