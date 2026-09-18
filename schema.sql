CREATE TABLE IF NOT EXISTS watch_backups (
  backup_key TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  item_hash TEXT NOT NULL,
  payload TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_watch_backups_expires
  ON watch_backups(expires_at);

CREATE TABLE IF NOT EXISTS maintenance_state (
  state_key TEXT PRIMARY KEY,
  last_run INTEGER NOT NULL,
  continue_watching_series INTEGER NOT NULL,
  batch_index INTEGER NOT NULL,
  batch_count INTEGER NOT NULL,
  scanned INTEGER NOT NULL,
  candidates INTEGER NOT NULL,
  attempted_writes INTEGER NOT NULL,
  verified_writes INTEGER NOT NULL,
  stopped INTEGER NOT NULL,
  error_codes TEXT NOT NULL
);
