# Changelog

## 1.2.0 — 2026-09-19

- Adds guarded cleanup for legacy `tmdb:` LibraryItem aliases that duplicate a canonical IMDb item in Continue Watching.
- Removed/temp aliases are eligible only when the video ID maps exactly to an active canonical IMDb item with matching media type and normalized name.
- Active aliases are eligible only when progress is exactly duplicated or is a stale near-zero pointer behind a newer canonical record.
- Adds a narrowly bounded completed-series residual-pointer rule: **<=15 seconds** plus Stremio Core's per-video 70% `timeWatched` evidence, watched flag, complete released-normal-season watched bitmap and exact final released episode pointer.
- Uses `state.lastWatched` as playback recency when present so unrelated LibraryItem `_mtime` changes cannot postpone safe cleanup.
- Confirms future-dated/TBC normal episodes do not block completion until released; once released and unwatched they block cleanup.
- Makes the Season 0 boundary explicit: ancillary specials such as panels, Episode Insider and behind-the-scenes material do not determine normal-series completion and are never mutated by this maintainer.
- Preserves meaningful low-progress final-episode rewatches, recent playback, insufficient Core watch-time evidence, ambiguous watched bitmaps and duplicate-video metadata.
- Only `timeOffset` is cleared; watched history and all unrelated state are preserved.
- Deterministic suite expanded to **26/26**, plus a live Dead City adversarial mutation pass covering 10 fail-closed fringe cases.

## 1.1.0 — 2026-09-18

- Extends automatic stale Continue Watching cleanup to movies using Stremio Core's native 90% credits threshold.
- Requires the movie to be flagged watched, past the credits threshold and quiet before clearing progress.
- Preserves lower-progress pauses and deliberate rewatches below the native credits threshold.
- Movie cleanup does not depend on metadata lookup.
- Adds four adversarial regression tests for movie completion semantics.

## 1.0.1 — 2026-09-18

- Adds hosted encrypted-backup list/export tooling.
- Adds a guarded recovery command for restoring a cleanup from an exported backup.
- Restore verifies account identity, exact current candidate state, second-read concurrency and post-write readback.
- Marks the npm package private to prevent accidental package publication.
- Normal production behavior is unchanged: private hosted cron, bounded cleanup and no public control surface.

## 1.0.0 — 2026-09-18

- Initial automatic hosted Continue Watching stale-completion maintenance release.
