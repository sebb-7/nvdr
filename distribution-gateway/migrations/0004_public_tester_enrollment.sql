ALTER TABLE invites ADD COLUMN requested_device TEXT;

CREATE TABLE IF NOT EXISTS public_signup_events (
  id TEXT PRIMARY KEY,
  requester_hash TEXT NOT NULL,
  invite_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_public_signup_events_requester_created
  ON public_signup_events(requester_hash, created_at);

CREATE INDEX IF NOT EXISTS idx_public_signup_events_created
  ON public_signup_events(created_at);
