# Track sandbox schema (ADR 0006 phase 2)

This release expands persistence and provides a dual-layout reader. It does not
create dedicated tracks or change terminal, preview, file, Vitals or MachineDock
routing. B5 must move those consumers before B7 activates dedicated writers.
The existing thread association and default-thread compatibility trigger remain
unchanged.

`Tracks.machine_for_track(user, track_id, opts)` establishes track access before
resolving ownership. `MachineCache.machine_for_track/4` accepts already authorized
rows. Shared rows still discover the project machine; a stored shared sandbox ID
is not verified ownership. Dedicated rows use only their persisted sandbox ID;
an unresolved ID returns `{:ok, nil}` and never falls back to another track.
Neither reader consults the rollout flag or treats lifecycle state as health.

The additive migration defaults every existing row and every old-writer insert
to `shared`, generation zero. No identity is inferred or automatically migrated:
issue #262 requires shared tracks to stay shared until close. Consequently there
is no resumable identity backfill in this phase. Nullable IDs remain unresolved
until a future authorized lifecycle writer records verified provider identities.
All legacy columns stay intact. The partial unique index applies only to non-null
dedicated sandbox IDs, allowing shared rows to name the same machine.

`RAVIX_DEDICATED_OPEN_USER_IDS` is a comma-separated allowlist of Ravix user IDs.
Unset/blank means off. `Config.dedicated_opens_enabled?/1` reports eligibility;
there are no provisioning callers in this release, even for eligible users.
B7 must check this after authorization, with the owner's live B2 verification
and B5 deployment as prerequisites. Disabling eligibility must never disable
reading or cleaning up an existing dedicated track.

`Tracks.Sandbox.Store` is an unscoped persistence boundary for B7. Callers must
establish access before using it. `begin_operation/3` locks an existing dedicated
track and compares its generation; it increments the generation and inserts
open/close/rebuild intent in one transaction. A stale caller gets
`{:error, :stale_generation}` without changes. `update_sandbox/3` conditionally
records verified IDs/state for that generation. It accepts atom-keyed internal
attributes and cannot switch layouts or generations.

Operations retain their original sandbox/vault IDs, with a resource map for
verified home-agent, environment and credential-set IDs. Progress stores attempt
counts, sanitized errors, cleanup obligations and completion. An optimistic
revision rejects lost updates. Old operations remain writable for cleanup after
a new generation starts, without touching the track. The foreign key restricts
hard deletion of a track with operation history; archive/close remains possible.
B7 must define lifecycle transitions, leases, retries, idempotency and provider
reconciliation before invoking these primitives. Database revision fencing alone
is not a provider-side lease. Do not put secrets or raw provider responses in
operation maps.
