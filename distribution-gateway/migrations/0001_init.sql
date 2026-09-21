CREATE TABLE IF NOT EXISTS invites (
    id TEXT PRIMARY KEY,
    code_hash TEXT NOT NULL UNIQUE,
    label TEXT NOT NULL,
    channel TEXT NOT NULL CHECK (channel IN ('beta', 'stable')),
    max_activations INTEGER NOT NULL DEFAULT 1 CHECK (max_activations > 0),
    activation_count INTEGER NOT NULL DEFAULT 0 CHECK (activation_count >= 0),
    expires_at TEXT,
    revoked_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    invite_id TEXT NOT NULL,
    label TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    channel TEXT NOT NULL CHECK (channel IN ('beta', 'stable')),
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    revoked_at TEXT,
    FOREIGN KEY (invite_id) REFERENCES invites(id)
);

CREATE TABLE IF NOT EXISTS releases (
    channel TEXT PRIMARY KEY CHECK (channel IN ('beta', 'stable')),
    version TEXT NOT NULL,
    update_object_key TEXT NOT NULL,
    installer_object_key TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    size INTEGER NOT NULL CHECK (size > 0),
    published_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type TEXT NOT NULL,
    subject_id TEXT,
    detail TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_invites_code_hash ON invites(code_hash);
CREATE INDEX IF NOT EXISTS idx_devices_token_hash ON devices(token_hash);
CREATE INDEX IF NOT EXISTS idx_devices_channel ON devices(channel);
