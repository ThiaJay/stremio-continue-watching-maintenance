# Continue Watching Maintenance for Stremio

Automatic, cross-platform maintenance for a narrow Stremio account-state defect: completed series and movies can remain in **Continue Watching** because completed playback progress is still stored.

## What it does

The scheduled Worker evaluates a bounded batch of movies and series with resume progress. For series it only acts when all currently released **normal-season** episodes are proven watched, the saved video is the final released normal episode and playback is not recent. A future-dated normal episode (including a TBC placeholder) does not count until its release date arrives.

The normal completed-series path preserves the existing conservative 70% resume-position rule. A second, narrower path handles the Stremio fringe case where a fully watched final episode is left with a tiny residual pointer near the beginning: the pointer must be **15 seconds or less**, Stremio Core's per-video `timeWatched` must independently prove the native 70% watched threshold, the final episode must be flagged watched and every currently released normal episode must be watched. Anything beyond that tiny residual window is preserved as a possible intentional rewatch.

Playback recency is taken from `state.lastWatched` when it exists, because Stremio Core updates that field while playing. The LibraryItem `_mtime` is still used for concurrency protection, although unrelated account changes no longer make old playback look recent.

Season 0 is deliberately outside this maintainer's completion authority. Panels, Episode Insider/aftershow material, behind-the-scenes programmes and similar extras therefore cannot keep an otherwise completed normal series stuck in Continue Watching. Narrative-special classification remains owned by Story Order; this maintainer does not mark any Season 0 item watched or rewrite its identity.

For movies it follows Stremio Core's own completion rule: the item must be flagged watched, playback must be quiet and stored progress must be beyond the native 90% credits threshold.

When those conditions are met it clears **only** the LibraryItem `state.timeOffset`. It does not mark episodes watched or unwatched and it does not change the watched bitfield.

If a new normal-season episode becomes released later, that episode remains unwatched and the show can naturally return to Continue Watching.

## Normal operating mode

This is a **hosted-maintenance** component. Normal operation is automatic on a private Cloudflare scheduled Worker every 10 minutes. It has no public HTTP control surface and requires no PC, startup task or local daemon.

Each run is bounded:
- deterministic batch of at most 8 eligible series;
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

The deterministic suite covers watched-bitfield decoding, completed-series qualification, future/TBC episodes, Season 0 ancillary material, residual-pointer cleanup, Stremio Core watch-time evidence, rewatch protection, playback-recency semantics, legacy-ID aliases, bounded batches, write caps, exact-field mutation and closure of the public HTTP surface.
