# Continue Watching Maintenance for Stremio

Automatic cross-platform maintenance for stale Stremio account resume state.

The production service is a private Cloudflare scheduled Worker. It runs every 10 minutes against the shared Stremio account state, so no client-specific process, browser extension or desktop daemon is required.

## Current production state

Version 1.7.4 is now the accepted production source. It adds an independent pre-write resume-only mutation invariant and exact episode and film regressions proving that resume cleanup cannot alter watched bits, watched counters, playback history or video identity.

The guarded production deployment completed on 24 September 2026 from source commit `b67a78374c18611dc6e5fa7d6761fa9fcd54e0ed`. Linux, Windows and macOS tests passed before deployment. The live Worker source matched SHA-256 `093bb76e1da6b6bb086ccced0c94138b2e2e143a7636ceea74d90f1d0289e089`, while the existing bindings and ten-minute cron were preserved.

Version 1.7.3 remains the latest immutable GitHub release until the 1.7.4 release package is published. A guarded production hotfix was deployed on 24 September 2026 from source commit `9ed1a5b9362eb532211cf3827d300ed51bb023e8`.

The hotfix adds recognition of explicit series title-level watched transitions that increment the series watched counter without changing the episode bitmap. This closes a case where a title can be marked watched yet retain stale Continue Watching progress.

Deployment verification preserved the existing Worker bindings and ten-minute cron, and the live Worker source matched SHA-256 `b87c79c1be33b1d5e665b5915a2589d7d34d1dd274e7053963358bcf8e3950d2`.

The original v1.7.3 production acceptance source was commit `94a4d5ef91d10211fe3a09f3dfc4eb2c5ef47495`.

The final secret-free Worker deployment preserves the ten-minute cron and the existing bindings. Production acceptance proved three independently reported Continue Watching examples at an exact zero resume offset with an encrypted pre-write recovery record for each repair. The temporary target secret used during acceptance was removed afterwards.

The immutable GitHub release v1.7.3 is published. Its tag points to clean packaging commit `4ac8e993493a4602cfab09ca06bcda1c478fc46c`, after the release gate proved `src/worker.js` was byte-for-byte identical to accepted product source `94a4d5ef91d10211fe3a09f3dfc4eb2c5ef47495`.

## Repair model

The maintainer clears only LibraryItem `state.timeOffset`. It never marks an episode or film watched or unwatched and never rewrites the series watched bitmap.

Several bounded lanes share the same safety model.

### Explicit watched intent

Recent series watched-bitfield transitions and explicit movie Mark as watched transitions are evaluated before ordinary maintenance. An initial observation is baseline only and cannot trigger a write.

Series intent requires every currently released normal-season episode to be watched, the pointed episode to be watched and the playback pointer not to have moved during the watched-state transition.

Movie intent requires the manual watched fingerprint to be distinguishable from natural playback. In particular, `timesWatched` must increment while the saved playback offset, watch time, duration, video identity and automatic watched-threshold state remain unchanged.

### Near-zero resume noise

A quiet positive resume pointer of one second or less can be treated as non-meaningful resume noise after the normal 30-minute playback quiet window.

This rule does not infer that a title is watched. It preserves watched state, watch time, video identity and all unrelated fields.

### Fully watched residual progress

For completed series the released normal-season watched bitmap is authoritative. The movie-only `flaggedWatched` field is not required.

A final released episode with meaningful completed progress can be cleared after the normal quiet guard.

A tiny pointer of 15 seconds or less has narrower rules. Core per-video watch time can independently prove native completion. Otherwise the residual must be stale for at least 24 hours.

A tiny pointer on an older watched episode is preserved as a possible rewatch unless every released normal episode is watched, the pointed episode is watched, both saved offset and per-video watch time are no more than 15 seconds and playback has been inactive for at least 30 days.

Future unreleased normal episodes do not block completion. A released unwatched normal episode does.

Season 0 is outside this maintainer's completion authority.

### Legacy aliases

A non-canonical `tmdb:` LibraryItem can be cleared only when it can be safely reconciled to an active canonical IMDb item with matching media type and normalised name under the dedicated alias rules.

### Reported issue priority

A visibly wrong Continue Watching item can be represented privately by a short hash with an expiry.

Reported priority does not create a new repair rule. The item must independently pass the same near-zero, alias, explicit-intent or completion decision that would allow an ordinary repair.

Reported items may take priority for one of the existing two normal write slots. The normal two-write ceiling is not increased.

The optional private target transport can come from D1 or an expiring Worker secret. Worker source contains no reported title or raw media identity.

## Metadata proof

Canonical series metadata is accepted only when it independently proves both the IMDb identity and the exact episode anchor embedded in Stremio's watched field.

The configured metadata service binding is tried first. Native Cinemeta is the fail-closed fallback under the same identity and anchor proof.

If no source can prove the mapping, no repair occurs.

## Write safety

Every account mutation requires all of the following.

- The expected Stremio account fingerprint still matches
- The complete current LibraryItem still matches the evaluated record
- A second immediate pre-write read still matches
- An encrypted pre-write recovery record is stored in private D1
- The write is bounded by the relevant lane cap
- Post-write readback reaches an exact zero `timeOffset` within a short bounded confirmation window
- Every unrelated state field remains byte-for-byte equivalent after normalisation
- Any ambiguity, concurrent drift or persistent readback mismatch fails closed

Normal automatic cleanup performs at most two account writes per run. Explicit watched-intent handling has its own bounded cap of six verified writes.

## Privacy

Operational observation data stores only short hashes and numeric progress or timing evidence. It does not store titles, raw media IDs, watched bitfields or account credentials.

Production credentials, account identifiers, private routes and Cloudflare resource IDs must never be committed.

## Recovery

Normal operation is automatic. Recovery is manual and guarded.

List encrypted hosted backups.

```text
npm run hosted-backups -- list
```

Export one recovery record into the ignored private folder.

```text
npm run hosted-backups -- export <backup-key>
```

Restore only after inspecting the exported record.

```text
node scripts/restore.mjs .private/hosted-watch-backup-....json --ack-account-write --auth-stdin
```

Restore verifies the expected account, requires the current LibraryItem to still match the cleanup candidate except for the Stremio modification timestamp, performs a second immediate pre-write read, restores the complete prior record and verifies the result by readback.

## Self-hosting

1. Create a private D1 database and apply `schema.sql`
2. Create an ignored local Wrangler configuration using `wrangler.example.toml`
3. Configure the `METADATA` service binding
4. Set `STREMIO_AUTHKEY`, `EXPECTED_ACCOUNT_FINGERPRINT` and `BACKUP_ENCRYPTION_KEY`
5. Run `npm ci`, `npm test` and `npm run check`
6. Deploy only after account identity, D1 recovery and metadata bindings are verified

The reported-item target secret is optional and should be short-lived when used.

## Tests

```text
npm ci
npm test
npm run check
npm audit --audit-level=high
```

CI runs the full suite on Linux, Windows and macOS.

## Related Stremio work

Stremio Watch State Reference specifies reusable watched-state transition invariants.

Story Order owns episode and special display ordering.

Library Artwork Repair owns artwork already persisted in Stremio LibraryItems.

Poster Safety owns live metadata artwork policy.

Stream and debrid readiness are separate from Continue Watching maintenance.
