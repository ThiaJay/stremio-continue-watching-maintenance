# Continue Watching Maintenance for Stremio

Automatic, cross-platform maintenance for a narrow Stremio account-state defect: completed series and movies can remain in **Continue Watching** because completed playback progress is still stored.

## What it does

The scheduled Worker evaluates a bounded batch of movies and series with resume progress. For series it only acts when all currently released **normal-season** episodes are proven watched, the saved video is the final released normal episode and playback is not recent. A future-dated normal episode (including a TBC placeholder) does not count until its release date arrives.

The normal completed-series path preserves the existing conservative 70% resume-position rule. A second, narrower path handles the Stremio fringe case where a fully watched final episode is left with a tiny residual pointer near the beginning: the pointer must be **15 seconds or less**, Stremio Core's per-video `timeWatched` must independently prove the native 70% watched threshold, the final episode must be flagged watched and every currently released normal episode must be watched. Anything beyond that tiny residual window is preserved as a possible intentional rewatch.

A separate transition-aware path handles explicit bulk watched intent. The Worker keeps only privacy-safe hashes and timing/progress snapshots for canonical series that currently have resume progress. If the watched bitfield changes from the previously observed state to a state where every released normal episode is watched, the playback pointer itself did not move during that watched-state change, the pointed episode is watched and playback was not recent, the stale `timeOffset` can be cleared even when it points to an older episode. This covers cases such as marking every season watched after an earlier rewatch without treating an already-watched rewatch as finished merely because its watched bits are still true. An initial observation is baseline-only and cannot trigger a correction.

Movies use the same principle with a stricter action fingerprint. **Watched** means historical completion; **resume progress** means an unfinished current playback session. Explicitly choosing **Mark as watched** should therefore dismiss stale current progress at that moment, without pretending the playback position reached the credits. The hosted maintainer recognises that action only when `timesWatched` increments while `timeOffset`, `timeWatched`, duration, video identity and automatic watched-threshold state are unchanged. Natural playback, a later rewatch, historical/external sync or any progress drift is preserved. A later play can create a fresh Continue Watching position normally.

Playback recency is taken from `state.lastWatched` when it exists, because Stremio Core updates that field while playing. The LibraryItem `_mtime` is still used for concurrency protection, although unrelated account changes no longer make old playback look recent.

Season 0 is deliberately outside this maintainer's completion authority. Panels, Episode Insider/aftershow material, behind-the-scenes programmes and similar extras therefore cannot keep an otherwise completed normal series stuck in Continue Watching. Narrative-special classification remains owned by Story Order; this maintainer does not mark any Season 0 item watched or rewrite its identity.

For movies it follows Stremio Core's own completion rule: the item must be flagged watched, playback must be quiet and stored progress must be beyond the native 90% credits threshold.

When those conditions are met it clears **only** the LibraryItem `state.timeOffset`. It does not mark episodes watched or unwatched and it does not change the watched bitfield.

If a new normal-season episode becomes released later, that episode remains unwatched and the show can naturally return to Continue Watching.

## Normal operating mode

This is a **hosted-maintenance** component. Normal operation is automatic on a private Cloudflare scheduled Worker every 10 minutes. It has no public HTTP control surface and requires no PC, startup task or local daemon.

Explicit watched-state transitions have a separate bounded priority lane. Recent series or movie transitions detected by the privacy-safe observation state are evaluated before the rotating ordinary maintenance batch, oldest first. The priority lane evaluates at most 12 items and performs at most 6 verified writes per run, while ordinary cleanup retains its existing 2-write cap. This prevents a burst of Mark as Watched or Mark Season as Watched actions from ageing out of the two-hour evidence window merely because the corresponding item is not in that run's rotating batch.

Series metadata is accepted only when it independently proves both the canonical IMDb identity and the exact episode anchor embedded in Stremio's watched bitfield. The configured AIOMetadata service binding remains the first source. If it cannot provide a trustworthy identity-and-anchor match, the Worker falls back to Stremio's native Cinemeta metadata and applies the same proof. A provider alias is accepted only when its explicit IMDb identity field matches the requested series and its video list contains the watched anchor. Ambiguous metadata still fails closed.

Each run is bounded:
- privacy-safe watched-state observation across canonical series with positive resume progress; unchanged observations cause no D1 write and store no titles or raw media IDs;
- deterministic metadata/evaluation batch of at most 8 eligible items;
- maximum 2 account writes;
- account fingerprint verification before evaluation and before mutation;
- complete-record concurrency checks;
- encrypted pre-write recovery record in private D1;
- immediate post-write readback proving that only `timeOffset` plus Stremio's modification timestamp changed;
- fail closed on ambiguity.

## What it is not

- **Stremio Watch State Reference** specifies watched/unwatched reconciliation and guarded bulk intent. It is deliberately on-demand and read-only.
- **Continue Watching Maintenance** is automatic production maintenance for stale completed resume progress.
- **Story Order** owns series episode/special ordering.
- **Poster Safety** owns live metadata artwork policy.
- **Library Artwork Repair** owns artwork already persisted in Stremio LibraryItems.
- Stream/debrid readiness and player continuity are separate domains.

## Cross-platform model

The authority is the shared Stremio account plus the hosted Worker. No client-specific process is required, so the correction applies regardless of whether the account is used from Windows, macOS, Linux, Android, Android TV or another Stremio client.

## Self-hosting

1. Create a private D1 database and apply `schema.sql`.
2. Copy `wrangler.example.toml` to an ignored local Wrangler config and insert the private D1 database ID.
3. Configure the `METADATA` service binding to a trusted metadata service that returns exact series identity.
4. Set Worker secrets:
   - `STREMIO_AUTHKEY`
   - `EXPECTED_ACCOUNT_FINGERPRINT`
   - `BACKUP_ENCRYPTION_KEY` (32 random bytes encoded base64url)
5. Run `npm test` and `npm run check`.
6. Deploy only after the account fingerprint and recovery database are verified.

Production credentials, account identifiers, D1 IDs and private metadata routes must not be committed.

## Recovery/admin

Normal operation remains automatic. Recovery is deliberately manual and guarded.

List encrypted hosted recovery records:

```text
npm run hosted-backups -- list
```

Export and decrypt one into the ignored `.private/` folder:

```text
npm run hosted-backups -- export <backup-key>
```

Restore only after inspecting the exported record:

```text
node scripts/restore.mjs .private/hosted-watch-backup-....json --ack-account-write --auth-stdin
```

Restore verifies the expected Stremio account, requires the current LibraryItem to still match the cleanup candidate except for Stremio's modification timestamp, performs a second immediate pre-write read, restores the complete prior record and verifies the result by readback. It fails closed on any intervening change.

## Tests

```text
npm ci
npm test
npm run check
```

The deterministic suite covers watched-bitfield decoding, completed-series qualification, future/TBC episodes, Season 0 ancillary material, residual-pointer cleanup, Stremio Core watch-time evidence, transition-aware bulk-watched intent, active-rewatch preservation, playback-recency semantics, privacy-safe observation state, legacy-ID aliases, bounded batches, write caps, exact-field mutation and closure of the public HTTP surface.
