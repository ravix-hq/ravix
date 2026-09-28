# RAV-14: dedicated project warm starts

Investigated 2026-09-28 for `r2-warm-start-visible` against Fountain main
`f941a837616eb48f20f144c265d34122e77206d9`.

## Finding

Dedicated tracks cannot inherit a project checkpoint on Sprites with the current
Fountain contract. Fountain's [Checkpoints implementation](https://github.com/managoat/fountain/blob/f941a837616eb48f20f144c265d34122e77206d9/apps/fountain/lib/fountain/conversations/checkpoints.ex)
disables checkpoint creation by default (`checkpoint_creation_enabled: false`).
Its explanation records a measured provider limitation: a checkpoint ID belongs
to the Sprite that created it. A fresh Sprite cannot restore another Sprite's
checkpoint. Enabling the flag alone therefore does not enable project warm starts.
An existing checkpoint is attempted, emits `checkpoint_restore` started, then
failed on an unavailable checkpoint, clears the environment ID and provisions cold.

This verifies the source contract, not the deployed Fountain revision, production
flag values, or a production restore experiment. Under this contract the answer
to “do dedicated tracks warm-start in prod?” is no for fresh Sprites; there is no
supported cross-Sprite restore. The owner's premise that automatic environment
checkpoint creation is already active does not hold in the inspected source.

## Ravix and mock path

- `Projects.Settings.environment/3` writes setup script and packages to the
  existing project environment. `Tracks.Sandbox.Store` records that environment
  ID on each operation; it does not create a per-track environment.
- `Tracks.Sandbox` copies the project vault for each track, refreshes clone
  credentials there, and launches a persistent conversation with the project
  environment, copied vault, home agent, channel, title and opening prompt.
  Optional model/inference selection is conversation configuration. It does not
  send replacement packages, repositories or setup script. Vault identity selects
  a different sandbox; Fountain's checkpoint lookup itself uses the environment,
  not the vault.
- Fountain's [FreshProvision pipeline](https://github.com/managoat/fountain/blob/f941a837616eb48f20f144c265d34122e77206d9/apps/fountain/lib/fountain/conversations/fresh_provision.ex)
  attempts the environment checkpoint before packages, repository clones and
  setup script. A successful restore skips those steps; networking still applies.
- Ravix's opening agent prompt creates/verifies the track's ordinary clone and
  branch after provisioning. `Tracks.Setup` verifies its listing and opening
  turn. It does not run the project's package/setup script again. That clone
  step is additional work, even if environment restoration eventually works.
- `Tracks.Transcript.Event` retains arbitrary stage names. `Follower` relays all
  events; LiveView marks stage activity and refreshes detail. The event is not
  dropped by transport, but `sandbox_stage` only reflects Ravix operation phases
  (creating/cloning/setup/ready); checkpoint stages never select setup status copy.
- `mock/server.ts` partitions sandbox disks by home identity including vault,
  emits turn stages, and has no environment checkpoint create/restore simulation.
  Its successful dedicated-open tests do not prove provider warm starts.

## Scope and measurement

Following item 4's stop condition, this change adds tracing and this finding only.
It does not add snapshot storage, checkpoint status copy, or a mock pretending
cross-Sprite restoration works. The conditional UI/mock acceptance cases are
therefore deferred until Fountain can support that operation.

There was no existing dedicated-open span: `Tracks.open/4` records durable intent
and reconciliation runs separately. A bounded `tracks.sandbox.open` completion
span now uses `Ravix.Trace` and the existing Honeycomb `ravix` configuration.
`ravix.open_to_ready_ms` measures persisted operation insertion through the ready
transition, including queue waits, retries and process restarts. Filter by
`ravix.open_action` (`open` versus `rebuild`) and group by `ravix.start_mode`:
`warm` only for a completed restore, `cold` for no restore or failed restore,
`unknown` for unavailable event history or an unfinished restore. No checkpoint
IDs or event bodies are exported. Span wall time is emission time; use the duration
attribute for comparisons. Closed/failed operations have no ready measurement.
The event-history read adds a paginated provider history read on successful opening; exporter
loss or a crash after the ready commit can lose the measurement (best effort,
not an audit ledger). Reconciliation does not re-emit completed operations.

To enable project warm starts, Sprites must offer cross-Sprite fork/import from a
checkpoint, and Fountain must use that API, safely restore project setup while
refreshing per-machine identity/secrets, then enable checkpoint creation. Ravix
can then surface the existing stage events; it does not need its own snapshot
system. Restoring a checkpoint onto the original Sprite is a different operation
and does not provide a fresh dedicated track with inherited project setup.
