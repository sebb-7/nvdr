CREATE TABLE IF NOT EXISTS beta_feedback (
  id TEXT PRIMARY KEY,
  invite_id TEXT,
  device_id TEXT,
  tester_name TEXT NOT NULL,
  category TEXT NOT NULL,
  message TEXT NOT NULL,
  contact TEXT,
  source TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_beta_feedback_created_at ON beta_feedback(created_at);
CREATE INDEX IF NOT EXISTS idx_beta_feedback_invite_id ON beta_feedback(invite_id);
CREATE INDEX IF NOT EXISTS idx_beta_feedback_device_id ON beta_feedback(device_id);
