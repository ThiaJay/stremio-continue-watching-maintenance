# Continue Watching Maintenance for Stremio

Automatic, cross-platform maintenance for a narrow Stremio account-state defect: completed series and movies can remain in **Continue Watching** because completed playback progress is still stored.

## What it does

The scheduled Worker evaluates a bounded batch of movies and series with resume progress. For series it only acts when all currently released normal-season episodes are proven watched, the saved video is the final released episode and playback is not recent. For movies it follows Stremio Core's own completion rule: the item must be flagged watched, playback must be quiet and stored progress must be beyond the native 90% credits threshold.

When those conditions are met it clears **only** the LibraryItem `state.timeOffset`. It does not mark episodes watched or unwatched and it does not change the watched bitfield.

If a new released episode appears later, that episode remains unwatched and the show can naturally return to Continue Watching.

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

The deterministic suite covers watched-bitfield decoding, completed-series qualification, future/new episodes, rewatch protection, recent playback, bounded batches, write caps, exact-field mutation and closure of the public HTTP surface.
