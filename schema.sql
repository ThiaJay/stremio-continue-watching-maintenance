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

CREATE TABLE IF NOT EXISTS watch_observations (
  item_hash TEXT PRIMARY KEY,
  watched_hash TEXT NOT NULL,
  watched_changed_at INTEGER NOT NULL,
  time_offset_at_change INTEGER NOT NULL,
  video_hash_at_change TEXT NOT NULL,
  last_watched_at_change INTEGER NOT NULL,
  mtime_at_change INTEGER NOT NULL
);
