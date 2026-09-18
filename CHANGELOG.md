# Changelog

## 1.0.1 — 2026-09-18

- Adds hosted encrypted-backup list/export tooling.
- Adds a guarded recovery command for restoring a cleanup from an exported backup.
- Restore verifies account identity, exact current candidate state, second-read concurrency and post-write readback.
- Marks the npm package private to prevent accidental package publication.
- Normal production behavior is unchanged: private hosted cron, bounded cleanup and no public control surface.

## 1.0.0 — 2026-09-18

- Initial automatic hosted Continue Watching stale-completion maintenance release.
