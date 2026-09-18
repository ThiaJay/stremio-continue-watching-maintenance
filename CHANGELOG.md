# Changelog

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
