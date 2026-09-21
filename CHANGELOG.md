# Changelog

## 1.6.7 — 2026-09-21

- Prevents an ancient-residual item from being planned twice when it is selected by both the bounded fast lane and the current ordinary rotating batch.
- Excludes already-planned ancient fast-lane item IDs from ordinary batch evaluation.
- Keeps the existing fast-lane selection, full metadata and watched-bitmap proof and normal two-write ceiling unchanged.
- Adds an end-to-end overlap regression requiring exactly one account write, one verified result and no stop condition when the same item belongs to both lanes.

## 1.6.6 — 2026-09-21

- Adds a bounded ancient-residual fast lane so clearly stale tiny completed-series pointers do not have to wait for the full rotating Continue Watching scan.
- Preselects only canonical series with a watched anchor, a positive offset of 15 seconds or less, per-video watch time of 15 seconds or less and at least 30 days of playback inactivity.
- Still requires the full trusted metadata identity proof, complete released-normal-season watched bitmap and watched pointed episode before creating a repair plan.
- Caps the fast-lane scan at 12 items and shares the existing two-write normal repair ceiling with the ordinary rotating batch.
- Keeps explicit watched-transition writes on their existing independent bounded lane.
- Adds end-to-end coverage proving an eligible ancient residual outside the ordinary batch is repaired through the same encrypted-backup and exact-readback path.

## 1.6.5 — 2026-09-21

- Extends stale residual cleanup to an already watched older episode only when the series is otherwise completely watched and the residual is clearly ancient.
- Requires the pointer episode itself to be watched, every released normal-season episode to be watched, both `timeOffset` and per-video `timeWatched` to be 15 seconds or less and playback inactivity of at least 30 days.
- Preserves recent older-episode pointers as possible rewatches and preserves any older rewatch with meaningful per-video watch time.
- Adds the exact live *Once Upon a Time in Northern Ireland* evidence where the 12.918 second stale pointer is on episode 1 rather than episode 5.
- Keeps metadata identity, watched-anchor, encrypted backup, exact-field readback, write caps and concurrency protections unchanged.

## 1.6.4 — 2026-09-21

- Adds a bounded stale-residual rule for a fully watched series whose final released episode is left with a tiny resume pointer of 15 seconds or less.
- Requires every released normal-season episode to be watched, the pointer to remain on the final released episode and playback inactivity of at least 24 hours when per-video watch time does not independently cross the native 70% threshold.
- Preserves recent tiny pointers as possible intentional rewatches.
- Adds an exact privacy-safe regression matching the live Once Upon a Time in Northern Ireland state: 12.918 second offset, 12.893 seconds watched, 4,509.040 second duration, movie flag zero and playback stale since 23 September 2025.
- Keeps all metadata identity, watched-anchor, D1 backup, concurrency and exact-field readback protections unchanged.


## 1.6.3 — 2026-09-21

- Fixes completed series remaining in Continue Watching when every released episode is watched but the movie-only `flaggedWatched` field is zero.
- Uses the canonical episode watched bitmap as the series completion authority, matching Stremio Core's series state model.
- Keeps existing metadata identity proof, watched-anchor validation, final released episode pointer, playback quiet-time and native watched-threshold guards.
- Leaves movie completion semantics unchanged.
- Adds a five-episode regression for *Once Upon a Time in Northern Ireland* proving a fully watched series with `flaggedWatched: 0` is eligible for stale progress cleanup.
- Clarifies that the residual-pointer path also relies on episode watched state and Core watch-time evidence rather than the movie-only flag.


## 1.4.0 — 2026-09-19

- Adds explicit-movie watched-transition handling so **Mark as watched** can clear stale Continue Watching progress without seeking to the end of the film.
- Keeps watched history and current-session progress as distinct concepts: a later rewatch can create fresh progress normally.
- Detects manual movie completion only when `timesWatched` increments while `timeOffset`, `timeWatched`, duration, video identity and automatic `flaggedWatched` state remain unchanged.
- Rejects automatic playback-threshold changes, external/historical watched sync, active playback drift and any ambiguous transition.
- Uses a privacy-safe v2 observation table containing only item/video/marker hashes plus numeric progress/timing evidence; no titles, raw media IDs or watched bitfields are stored.
- Adds direct and end-to-end break tests for manual movie watched intent, later rewatches, automatic threshold completion and historical/external sync.
- Deterministic suite expanded to **37/37**.
- Charlie and the Chocolate Factory was repaired under explicit user-confirmed watched intent with encrypted hosted recovery evidence and exact-field readback.

## 1.3.0 — 2026-09-19

- Adds privacy-safe watched-bitfield transition observation for canonical series with positive resume progress.
- A first observation is baseline-only and can never trigger an account write.
- A subsequent watched-state change can clear stale progress only when every currently released normal episode is watched, the pointed episode is watched, the playback pointer did not move during the watched-state mutation and playback was not recent.
- This closes the explicit bulk-watched fringe case where every season is marked watched after an earlier rewatch while preserving active or recently paused rewatches.
- Observation storage contains only hashes and numeric timing/progress evidence; no titles, raw media IDs or watched bitfields are stored.
- Adds fail-closed tests for baseline state, active rewatches, pointer drift, future/released episodes and an end-to-end two-run observed-transition cleanup.
- Deterministic suite expanded to **32/32**.
- Footballers' Wives was repaired under explicit current user intent with encrypted hosted recovery evidence, exact-field readback and watched history unchanged.

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
