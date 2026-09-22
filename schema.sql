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

CREATE TABLE IF NOT EXISTS watch_observations_v2 (
  item_hash TEXT PRIMARY KEY,
  media_type TEXT NOT NULL,
  marker_hash TEXT NOT NULL,
  changed_at INTEGER NOT NULL,
  time_offset INTEGER NOT NULL,
  time_watched INTEGER NOT NULL,
  times_watched INTEGER NOT NULL,
  flagged_watched INTEGER NOT NULL,
  duration INTEGER NOT NULL,
  video_hash TEXT NOT NULL,
  last_watched INTEGER NOT NULL,
  mtime INTEGER NOT NULL,
  prev_time_offset INTEGER NOT NULL,
  prev_time_watched INTEGER NOT NULL,
  prev_times_watched INTEGER NOT NULL,
  prev_flagged_watched INTEGER NOT NULL,
  prev_duration INTEGER NOT NULL,
  prev_video_hash TEXT NOT NULL,
  prev_last_watched INTEGER NOT NULL,
  prev_mtime INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS diagnostic_results_v1 (
  item_hash TEXT PRIMARY KEY,
  observed_at INTEGER NOT NULL,
  payload TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS repair_targets_v1 (
  item_hash TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  last_attempt INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_repair_targets_v1_expires
  ON repair_targets_v1(expires_at);
