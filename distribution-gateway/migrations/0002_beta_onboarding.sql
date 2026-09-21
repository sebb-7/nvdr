ALTER TABLE invites ADD COLUMN access_days INTEGER NOT NULL DEFAULT 30;
ALTER TABLE devices ADD COLUMN access_expires_at TEXT;

CREATE TABLE IF NOT EXISTS program_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
