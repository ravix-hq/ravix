---
type: ADR
title: "A sandbox per track, with threads sharing its clone"
description: "Proposes a persistent sandbox and ordinary clone per track, replacing project machines and git worktrees; per-project runtime agents, per-track vaults and concurrent threads remain proposed and require live provider verification."
tags: [architecture, tracks, sandboxes, fountain, lifecycle]
status: draft
adr: "0006"
adr_status: "Proposed"
date: 2026-09-22
generated: { by: process:codex, at: 2026-09-22T00:00:00Z }
stale_after: 2026-10-22
---

# 0006 — A sandbox per track

**Status:** Proposed. Documentation and investigation only. None of the layout,
state machine, migrations or PR phases below is implemented by this change.
The current-code findings were checked on `f5af60f`; provider capabilities beyond
Ravix's client, pinned SDK and Bun mock have not been verified against a live Fountain or
Sprites. The 2026-09-27 amendment below records the newer provider contract
and product decisions; it does not claim live verification. Integrate the
existing thread schema and APIs rather than introducing a second thread model.

## Amendment — 2026-09-27

This Proposed ADR incorporates [#262](https://github.com/ravix-hq/ravix/issues/262),
including Fountain ADR 0023's 2026-09-26 amendment (#2517–#2522) and ADR 0061.
It supersedes the original distinct-agent-per-track isolation with at most one
agent per runtime per project and a per-track vault. Runtime/model selection is
per thread; concurrent turns on the shared checkout are allowed. A feature flag
replaces admission caps. Rebuild and close delete the sandbox, not its agent.
The corresponding decisions and implementation phases are amended inline below.

Project switcher decisions 5–7 and their implementation are separate work; #262
places that work before the sandbox rollout. This amendment implements plan item
`r6-adr0006-amend` only. All sandbox behavior below remains Proposed.

## Context

The team's premise is: “every track is basically a workspace with its own
sandbox. We also won't need git worktrees anymore.” Today the project is the
machine boundary. There is no persisted project sandbox id:
`MachineCache.machine_of/3` (including its default-argument `/2`) selects the
newest live conversation with a sandbox from the project's agent. Ending the
last conversation can therefore make a persistent disk disappear from discovery.
`Projects.Machine.state/1` also derives state from conversations, including ended
ones, rather than reading sandbox health.

`Tracks.plan/4` launches against that machine or provisions through a new
conversation. `Spec.system_prompt/1`, `open_track_prompt/4` and
`close_track_prompt/3` tell the agent to create and remove a worktree under
`/home/sprite/work`, leaving the shared clone alone. Scratch projects use plain
directories. The prompts, not an enforced filesystem boundary, separate tracks.
`Projects.Machine` prepares credentials, refreshes the clone token, rebuilds the
project agent and closes every track on rebuild. Terminal, Vitals, file reads,
previews and MachineDock all derive their target from the project machine.

A track will have multiple threads, each with its own Fountain conversation.
A conversation is an execution/history unit; a track is the durable workspace.
Ending a thread must not lose that workspace or change which disk another
thread sees. Separate tracks should be able to work without sharing ports,
files, branch checkouts or one machine's turn capacity.

This proposal changes the project-machine assumption in
[0002](0002-elixir-and-liveview.md) and the machine-related portions of
[0005](0005-each-person-brings-their-own-agent.md). It retains the owner's
subscription billing rule and the clustering rules of
[0003](0003-cluster-and-transparent-deploys.md). It does not change the product
scope or implement native previews or a shared browser. Instrumentation follows
[0004](0004-telemetry-honeycomb-and-posthog.md).

## Decision

Give each newly opened track one persistent Fountain sandbox containing an
ordinary clone checked out on the track's branch, or a workspace directory for
a project without a repository. Persist its sandbox id on the track. All its
threads attach using the home identity or the permitted other-runtime guest
identity. Closing the track ends its conversations and terminates its sandbox;
ending a thread does neither to its siblings. Projects become repository/settings/billing templates,
not machine owners. Remove worktree creation, cleanup and discovery from the
new layout, retaining the old path only while existing shared tracks drain.

### Ownership and identity

Proposed additive track fields are `sandbox_layout` (`shared` or `dedicated`),
`sandbox_id`, `sandbox_generation`, `sandbox_state`, and the provisioned identity
ids (including `vault_id`, plus the home agent, environment and credential-set
references needed to reconcile a generation). Agent ownership stays on the
project. These are ownership and desired-lifecycle records, not a claim that
the provider is alive.
Read provider health separately and represent unknown/unavailable explicitly.
Keep `workdir` as the actual clone/workspace root; do not overload a slug as a
filesystem identity. A partial unique index on non-null dedicated sandbox ids
prevents two tracks from owning one sandbox; shared rows may name the same id.

Use at most one Fountain agent per runtime (`claude` and `codex`) per project,
creating the other runtime's agent on first use. A dedicated track gets its own
vault containing the clone token and project secret snapshot. The vault is part
of Fountain's home identity key `(agent, environment, vault)`, so different track
vaults produce distinct disks even when tracks use the same project agent.
Keep the environment/vault identity stable for a sandbox generation. Provider
metadata should name the track and generation for reconciliation, without secrets.

The first thread's runtime selects the home agent. Many conversations of that
agent may use the sandbox. One agent of the other runtime may join by
`sandbox_id` with the same user, environment and vault. Two agents of the same
runtime cannot share it. The machine lifecycle follows the home agent; deleting
a guest ends only its conversations. Never delete a shared project runtime agent
to rebuild or close a dedicated track: use `DELETE /api/sandboxes/:id`.

The project owner's inference credential set remains shared, by design. A
track vault holds its clone token and the applicable project secret snapshot;
project secret changes need explicit per-track propagation and reporting.
Environment provisioning and vault copying need failure cleanup and may add
provider quota and storage cost. Do not delete a project template while legacy
tracks need it.

Threads store their conversation ids and belong to a track. They do not own
sandbox ids or provision independently. Creating a thread waits for the track
to become ready, then sends the home or other-runtime project `agent_id`, the
same `environment_id` and `vault_id`, and the stored `sandbox_id`. Retain explicit
nils in `Fountain.Launch` and its encoding rules. Check the returned sandbox
against the expected id before binding the thread; mismatch fails closed and queues cleanup of the unexpected resource.
Choose thread-specific channel ids with the parallel threads implementation;
Fountain channel membership must not be used as a substitute for track ownership.

### Runtime, model and concurrent threads

Each thread chooses its runtime and model. The new-track form chooses these for
its first thread; the track remembers its last runtime as the next thread's
default, with the project supplying the overall default. Fountain ADR 0061
allows a conversation's model to differ from its agent's model. Add nullable
`runtime` and `model` fields to the existing thread schema with project fallback.
Pickers offer only runtimes the **project owner** has connected, using
`Inference.usable?` and #255's picker pattern; members see unconnected runtimes
as “Not connected” and cannot select them. Both Claude-on-Codex and
Codex-on-Claude home sandboxes must work.

For dedicated tracks, changing the project's runtime or model changes only the
default for new threads, without rebuilding or changing existing threads.
This supersedes #238's “Switch and rebuild” for dedicated tracks. Retain that
legacy action while shared tracks remain, explain the distinction in settings,
and restrict its destructive effects to shared tracks.

All threads share one checkout and branch. Concurrent turns are allowed, like
multiple terminals; show which other threads are mid-turn. File/git collisions
are the user's responsibility, including manual terminal writes. Fountain runs
turns concurrently up to a per-runtime limit and returns `sandbox_at_capacity`
beyond it; Fountain provides no queue. Ravix's prompt queue may retry capacity
failures but must not serialize all turns within a track. Separate tracks run
independently, subject to provider quotas. Branch creation/fetch and branch/PR/issue
origins operate in an ordinary clone, never `git worktree add`. Keep existing
push/merge authorization rules. No implicit push occurs on close.

Both runtimes can read each other's credential files on a mixed sandbox;
Fountain hides them from transcripts. This is acceptable under ADR 0005 because
both use the same project owner's credentials, not different billing identities.

### Lifecycle and recovery

Persist lifecycle intent before provider side effects. Proposed states are
`provisioning`, `ready`, `failed`, `closing`, and `terminated`; sleep is observed
provider state, not track closure. A durable operation record keyed by track,
generation and action records attempts, resource ids, errors and cleanup work.

1. **Open:** authorize track creation, check the dedicated-open feature flag and persist
   the track row and operation intent. Create its vault with a clone token and
   project secret snapshot, then provision through the project home-runtime
   agent with that vault and an initial
   opening prompt in the conversation-create request. Record the resulting
   sandbox and first thread; wait for clone/setup/branch initialization before
   advertising readiness, integrating #240's setup gate. A scratch workspace
   skips cloning. The provisioning
   conversation becomes the first thread rather than an invisible extra runner.
2. **Retry:** retry a failed step against the same operation and generation.
   A timeout is an unknown outcome, not permission to create another sandbox.
   Reconcile provider resources by an idempotency key or stable operation
   identity before resending. Record and retry orphan cleanup if persistence
   fails after allocation. Setup retry must not reset an existing dirty clone.
   Surface capacity, clone authentication and setup failures distinctly.
3. **Attach/wake:** refresh this track's token and check credential compatibility
   before new sessions or queued turns. Resume the stored sandbox; never fall
   back to the project's newest conversation. A missing disk is a visible loss
   requiring explicit rebuild, not an automatic replacement of unpushed work.
4. **Close:** reject new threads/prompts, cancel queued work, revoke preview
   grants and stop its service/leases; terminate every thread conversation and
   delete the sandbox with `DELETE /api/sandboxes/:id`. No agent cleanup turn
   is needed for a dedicated disk. Persist
   `closing` and retry failures after process/node death; only confirmed deletion
   (or a provider-confirmed already-gone response) completes resource cleanup.
   The UI may archive the track immediately but must expose pending cleanup.
   Closing during provisioning fences late results and cleans their resources.
5. **Rebuild:** explicitly discard/replace only this track's workspace after the
   existing destructive-action confirmation. Quiesce its threads and preview,
   retain transcript history, delete the old sandbox with
   `DELETE /api/sandboxes/:id`, confirm deletion, then provision a new generation
   through the project runtime agent with a per-track vault identity. Keep
   cleanup records for the old resources until done.
   Never close sibling tracks. Project deletion fans out durable closes before
   retiring templates. A project runtime/default change does not rebuild
   dedicated tracks.

Close means the local clone, uncommitted changes and unpushed commits can be
lost. Offer the existing close choice with an accurate warning and check dirty
and unpushed state when reachable; an unreachable disk requires an explicit
force choice. Pushed branches/PRs remain. Remote branch deletion is a separate
explicit action, not an effect of sandbox termination. Retention/export before
close remains an open product question, not an assumed provider guarantee.

**Credentials:** move `prepare_machine`, `adopt_credentials` and clone-token
refresh to track-scoped orchestration. Do not mutate a shared project agent to
repair one dedicated track. ADR 0005 still means that *any write* to an owner's
inference set invalidates conversations bound to the old revision across
**all threads, tracks and projects using that set**. It does not mean destroying
their disks or closing their track rows. Show the reason, stop retrying refused
old conversations and start replacement threads on a compatible sandbox after
repair. A Codex change of credential source may require a track rebuild; do not
promise that a new conversation alone fixes `codex_inference_conflict`.
Clone-token writes to track vaults are not inference-set revision writes.

### Cost, capacity and sleeping

For N open dedicated tracks a project owns N persistent machines, rather than
one shared machine. Every new track incurs provisioning plus clone/setup cold
start, duplicated repository/dependency storage and identity records. More
parallelism also means more simultaneous owner subscription usage. Closing must
actually reclaim a sandbox; conversation termination alone cannot establish
that costs stopped.

Idle open tracks should retain their disk while Fountain parks execution and
Sprites sleeps compute according to verified provider behavior. A running
preview/activity lease may keep that track awake. Ending the last thread must
not delete its sandbox. Closing releases leases and destroys the sandbox;
parking is not deletion and may still bill for storage. Ravix does not currently
expose a park/wake sandbox API; do not add an invented idle timeout to the design.

There are no Ravix open-sandbox caps for now (#262 decision 9). A per-user or
cohort feature flag, off by default, limits who can open dedicated tracks.
Turning it off stops new dedicated opens; every release must still read both
layouts and maintain existing resources. Provider account quotas, rate limits
and per-runtime `sandbox_at_capacity` remain distinct errors to surface and
handle. Gather usage/cost measurements without making numeric admission limits
an enablement prerequisite.

### Previews, terminal and vitals

Terminal, file/diff reads and Vitals resolve `track.sandbox_id` after
`Access.track_access/2`; resource usage now describes the selected track.
MachineDock becomes a selected-track machine panel. A project overview can
aggregate track state but must not choose one “project machine.” Cache sprite
metadata by sandbox id and fence results by generation; it is not ownership.

A dedicated sandbox may use the same preview port as every other sandbox,
removing the cross-track allocation problem. Keep `$PORT`, collision failure,
readiness, current-host HMR and the authenticated gateway. A port can still
collide with a process inside this track. Preserve preview generations, session
revocation, single-use tickets and track access checks. Stop services and revoke
grants on close/rebuild. Keep the current `(sprite, port)` allocator/index for
legacy shared machines until contract; preview hostname/ticket identity remains
track-scoped. A copied clone does not simplify browser authorization away.

### Cluster and rolling deploys

Follow ADR 0003: track lifecycle and preview workers use `Cluster.via/2` and
node-local supervision; a durable cleanup reconciler uses `Cluster.Singleton`.
Thread followers should be keyed by thread as agreed with the threads change,
and callers monitor them and reconnect from their own cursors. The prompt
queue keeps its atomic claims and per-instance sweep.

`:global` is coordination, not an exactly-once provider transaction: joining
nodes can briefly duplicate ownership, and a node may die after a provider
accepted a request. Conditional database transitions, generation fencing and
provider idempotency/reconciliation must prevent double allocation and stale
completion. Do not hold a database transaction open for a network call. On
name conflict workers stand down as in ADR 0003; a successor resumes recorded
intent. Broadcast state changes, recheck access on async results, and do not
let a node-local cache overwrite newer generations or strand existing waiters.

### Existing shared machines

**Keep existing shared tracks until they close**, with no automatic migration. An existing worktree can contain unpushed commits, dirty files,
untracked data, setup artifacts and running services that a fresh clone cannot
reconstruct. Preserve its branch, workdir, conversations and shared-machine
identity. Mark existing rows `shared`; backfill sandbox ids only from verified
conversation/identity matches. Unknown ownership remains unresolved, never
assigned from an unrelated newest conversation.

New tracks use `dedicated` after the feature gate opens. Legacy close removes
only that track's worktree/conversations; it must never terminate a shared
sandbox with other open tracks. When the last legacy track closes, durable
cleanup retires the old project machine after checking all associated threads
and previews. Keep shared rebuild semantics explicit and prevent an old
project rebuild from closing new dedicated tracks. Retire unused project
identity records only after their last dependent resource is gone.

Ship readers for both layouts to every instance **before** enabling dedicated
writers. Rolling back then means disabling new dedicated opens while keeping
the compatible release; reverting to a release that assumes one machine per
project is unsafe. Track the remaining shared rows and cleanup backlog. Any
future removal of dual readers needs a new decision, zero legacy dependencies
and an elapsed rollback window. Optional migration
later must quiesce threads, export and verify all local state and retain the old
disk until the user accepts the replacement; it is not required for this rollout.

### Fountain client and mock investigation

These are baseline repository findings from the original investigation, with
the SDK reset endpoint and #262 contract noted; they are not live verification:

| Capability | Current support and implication |
|---|---|
| Provision | `lib/ravix/fountain.ex` `create_conversation/2` posts with `sandbox_mode: "persistent"` when no sandbox id is given. `fountain/launch.ex` documents the initial-prompt requirement after provisioning without it returned 422. Keep the prompt in the provisioning request. There is no standalone sandbox-create wrapper here. |
| Attach | The wrapper sends `sandbox_id` plus agent/environment/vault identity. Extend its contract tests for the other-runtime guest using the same user/environment/vault. Partial identity can cause `sandbox_identity_mismatch` or accidental allocation; a channel id alone does not isolate machines. The wrapper always sends `fresh: true`, so channel reuse is not a retry idempotency mechanism. |
| Inspect | `sandbox/2` reads `GET /api/sandboxes/:id`; conversation get/list and sandbox file/list/diff reads exist. List responses cannot be relied upon for embedded sprite data. |
| End a conversation | `terminate/2` posts to `/api/conversations/:id/terminate`. This is not an explicit sandbox termination API. Current rebuild deletes the old agent to force a different identity; that does not establish a verified disk-deletion contract. |
| Sandbox lifecycle/recovery | The pinned `fountain_sdk` 0.6.0 already offers `Fountain.sandboxes/2` (status-filtered list) and `reset_sandbox/2` (`DELETE /api/sandboxes/:id`), but Ravix exposes neither. Adapt these after verifying reset/deletion completion and live-conversation behavior; their absence in Ravix is not evidence of a missing upstream endpoint. No Ravix support for listing by operation identity, idempotent allocation, explicit park/wake or quota inspection was found. Upstream work is conditional on those recovery/capability gaps. Do not bypass Fountain by deleting a Sprite underneath it. |
| Bun mock | `mock/server.ts` keys `state.boxes` by agent id, reuses the box on a no-id launch, validates attach identity and serializes turns per sandbox. Conversation terminate releases busy state but leaves the box. Its sandbox-id route is a read-shaped response without an HTTP-method guard, not a faithful deletion implementation. It cannot prove real cleanup, sleeping, billing or timeout reconciliation. |

The SDK README also describes `Run.terminate` as tearing down a sandbox; that
general description does not settle persistent, shared-conversation semantics.
Verify disk retention when a thread ends rather than trusting the mock.

Phase 1 supplies `scripts/fountain-sandbox-check.exs` (or `.py`) for the owner
to run against real Fountain with their own token and a disposable test project.
Coding agents do not have Fountain API credentials and must not run it. The
script cleans up everything it creates, prints a pass/fail table and never tokens.
It verifies: two per-track vault identities produce distinct sandboxes; an
other-runtime guest attaches by `sandbox_id`; two threads share one disk;
terminating a thread preserves that disk; DELETE removes only its sandbox and
reports completion; and a lost create response can be reconciled without double
allocation (or explicitly reports that it cannot). Live results are an enablement
gate. Client/mock tests encode the contract but cannot substitute for that gate.

## Consequences

Isolation becomes a machine boundary rather than prompt discipline, and one
track's rebuild or preview no longer affects another dedicated track. Provider
account and owner subscription limits can still affect turns across tracks.
The cost is more machines, cold starts, duplicated caches and explicit resource
ownership/cleanup in Ravix. Threads still share a disk and subscription limits;
this does not provide isolation between threads or between billing identities.

The rollout temporarily has two layouts and two cleanup paths. Keeping that
complexity explicit is safer than silently abandoning local work. Storing a
sandbox id requires reconciliation, but avoids treating conversation liveness
as disk ownership. No promised latency, pricing or quota figure is supplied
without provider evidence.

## Phased implementation plan

Each numbered phase is a separately shippable PR (split further if needed).
In #262's plan, B1 is this amendment; B2 implements phase 1; B4 and B5 implement
phases 2 and 3; B7 and B8 implement phases 4 and 5. B3 adds runtime/model to the
existing threads and forms after B2, including owner-connected pickers,
last-runtime defaults, guest launch and mid-turn visibility. The dependencies
are B1 → B2 → B3 and B1 → B4 → B5, then B7 after both B2 and B5, then B8.
The project switcher (B6, ravix5) is separate work.

All implementation PRs keep access checks in scoped contexts, row operations in
Stores with ownership comments, supervised work and existing coverage floors.
Run focused tests and `mix precommit`; browser-affecting phases also run
`bun run test:browser`. This ADR/index PR changes no runtime behavior.

1. **Verify and encode the provider contract; keep creation disabled.** Touch
   `lib/ravix/fountain.ex`, `lib/ravix/fountain/{launch,shapes,error}.ex`,
   `mock/server.ts`, `test/ravix/fountain_test.exs` and
   `test/ravix/mock_contract_test.exs`. Add verified sandbox cleanup and
   reconciliation adapters, exposing the SDK's existing `reset_sandbox/2`
   (`DELETE /api/sandboxes/:id`) and sandbox list/status reads. Encode the home
   and other-runtime guest rule, same-runtime guest refusal, vault-distinct disks,
   per-runtime concurrent capacity, and delete ending all sandbox conversations.
   Add the owner-run verification script described above, with explicit
   unsupported-capability errors.
   Coordinate any missing upstream Fountain endpoints/idempotency semantics
   first. Test full identity, provisioning prompt/422, distinct identities,
   sibling attachments, conversation-vs-sandbox termination, already-gone,
   timeout/unknown outcome and quota responses. Real provider acceptance above
   is an enablement gate; a permissive mock is not evidence.
2. **Expand schema and introduce dual-layout reads, no new dedicated writes.**
   Touch additive `priv/repo/migrations/*`, `tracks/{track,store,opening}.ex`,
   `tracks.ex`, `machine_cache.ex`, and new track lifecycle/operation schema and
   Store modules. Add nullable ownership fields, durable open/close/rebuild
   operation records and an off-by-default dedicated-open feature flag; default
   existing/old-writer rows to shared. Backfill resumably with
   verified identities; keep old fields. Integrate the existing thread
   association rather than adding a second thread model. Test old/new row
   round trips, uniqueness, unresolved legacy ids, interrupted backfill,
   generation compare-and-swap, scoped reads and mixed-version compatibility.
3. **Make all consumers understand both layouts before switching writers.**
   Touch `projects.ex`, `projects/{machine,machine_state,view}.ex`, `tracks.ex`,
   `terminal.ex`, `vitals.ex`, `previews/{lifecycle,store,agent,reconciler}.ex`,
   `ravix_web/live/machine_dock.ex`, `ravix_web/{track_live,workspace_live}.ex`
   and their tests (paths under `lib/` unless stated otherwise). Resolve by
   track, retain the legacy fallback only for explicitly shared rows, and gate
   shared rebuild/cleanup to shared tracks. Test different sandbox ids within
   one project, track-only membership, revoked sessions, stale async results,
   preview tickets/generations and terminal/file/vitals isolation. Browser
   tests cover selected-track machine status and preview navigation. Deploy
   everywhere before phase 4 can be enabled.
4. **Ship durable open/close behind the dedicated-open feature flag (B7).**
   Touch `lib/ravix/tracks.ex`, `tracks/{opening,setup,store}.ex`,
   `application.ex`, `spec.ex`, `ids.ex`, `prompt_queue/server.ex` and thread
   launch integration (remaining paths under `lib/ravix/`). Add concrete
   `Ravix.Tracks.Sandbox`, `Ravix.Tracks.Sandbox.Operation`,
   `Ravix.Tracks.Sandbox.Store` and `Ravix.Tracks.Sandbox.Reconciler` modules
   under `tracks/sandbox.ex` and `tracks/sandbox/` for orchestration, durable
   intent and cleanup. Reconcile behind `Cluster.Singleton` (ADR 0003).
   Persist intent before creating a per-track vault (clone token plus project
   secret snapshot); provision through the project's home-runtime agent with
   that vault. Create an ordinary clone on the track branch; scratch projects
   skip cloning. Integrate #240's verified setup gate for opening turns.
   Close ends conversations and uses B2's DELETE adapter, with durable retries.
   Keep shared tracks in place until close; remove the old project machine only
   after its last shared track and dependent resources are gone.
   Test double open, close-during-open, clone/setup failure, provider success
   before DB failure, node crash after allocation, duplicate close, per-runtime
   capacity and orphan recovery. Add peer-node cases in
   `test/ravix/cluster/distribution_test.exs` with `test/support` helpers.
   Browser tests cover readiness, retry, flagged/unflagged opens and pending
   cleanup. Depends on B2's provider contract and B5's deployed dual readers.
   Enable only after the owner's live provider checks pass. Rollback disables
   new dedicated opens and retains dual readers; no admission caps are added.
5. **Complete per-track maintenance and runtime-default settings (B8).**
   Touch `lib/ravix/projects/{machine,settings}.ex`,
   `projects/machine/{harness,rebuild}.ex`, `accounts/inference.ex`,
   `prompt_queue/server.ex`, `tracks/sandbox{,/store,/reconciler}.ex`, and new
   `tracks/sandbox/maintenance.ex` (`Ravix.Tracks.Sandbox.Maintenance`). Update
   `previews/{store,lifecycle}.ex`, `lib/ravix_web/live/machine_dock.ex`,
   `lib/ravix_web/{workspace_live,track_live}.ex` and settings/track actions.
   Rebuild deletes only the selected sandbox through the SDK's existing
   `reset_sandbox/2` adapter, confirms removal and provisions a new generation.
   Scope credential adoption and clone-token refresh to that track; never delete
   a project runtime agent to repair one workspace. Project deletion fans out
   durable closes. Reuse one preview port across dedicated sandboxes.
   For projects whose open tracks are all dedicated, runtime/model changes only
   update defaults for new threads. Keep #238's “Switch and rebuild” while shared
   tracks remain, with explicit UI wording and no dedicated sibling teardown.
   Apply ADR 0005 inference-set invalidation and #260's project-health banner
   when the owner disconnects a runtime; the thread recovery policy remains an
   open question below, not an implicit destructive rebuild.
   Test sibling isolation, old-generation cleanup, token refresh retry,
   inference revision invalidation across projects/threads, Codex source
   conflict, secret propagation and both layouts' settings behavior. Test legacy
   port allocation and dedicated port reuse. Browser tests cover destructive
   wording, default-only changes, repair and unaffected sibling tracks.
6. **Drain and contract in later releases.** After telemetry shows no legacy
   tracks, previews, pending operations or identity dependencies, consider
   any proposed removal of shared discovery fields/prompts/allocator behavior
   only under a later explicit decision: #262 requires every release to read
   both layouts. This phase is not authorization to remove dual readers.
   Touch `spec.ex`, `machine_cache.ex`, `projects/machine*.ex`, track/preview
   Stores, mock fixtures, tests and machine-related documentation including
   ADR 0005. A subsequent migration PR drops only genuinely unused fields and
   constraints; retain project settings/templates and sandbox lookup caches
   still needed. Do not drop `conversation_id` independently of the threads
   migration's contract. Test upgrade from legacy fixtures, last-shared-track
   cleanup, project deletion, migration ordering and rollback within the
   supported window. Remove the feature gate only after dedicated operation
   and cleanup have been observed; update this ADR's built/unbuilt accounting.

## Open questions for the team

- **Fountain/Sprites numbers:** What are the per-account sandbox, agent,
  environment, vault and concurrent-provisioning ceilings? What turn/session
  concurrency limits apply per runtime, and what API rate limits apply per
  sandbox and per account? What
  compute, disk, snapshot and egress prices apply while active, sleeping,
  parked and closing? What are idle timeouts, wake latency and disk retention
  guarantees? Request measured provisioning + clone + setup p50/p95 timings
  by repository size, wake timings, and cleanup completion bounds. Use these
  to inform retry budgets, user-visible estimates and future rollout review,
  not to introduce caps in this decision.
- Does Fountain support idempotent allocation and lookup by operation key,
  reliable deletion confirmation, and discovery of orphaned sandboxes? Which gaps
  require upstream changes and what capability/version gates can Ravix use?
- How are project secrets/settings propagated to per-track vault snapshots
  without changing disk identity, and how are partial failures reported?
- If the owner disconnects a runtime, what happens to that runtime's threads on
  open tracks? ADR 0005 requires invalidation, but recovery/resume UX is still
  open; coordinate the project-health banner (#260).
- Can Codex attach with a new revision of the same source on an existing disk,
  and which credential changes require replacement? How should users resume
  affected threads while retaining conversation history?
- Confirm the threads PR's channel, queue, follower and history contracts.
  How should mid-turn visibility help users coordinate concurrent threads and
  terminal writes? Concurrent branches inside a track are out of scope.
- What retention/export or recovery experience should precede destructive close
  and rebuild, and should users be offered a separate park action? Who can
  force-close an unreachable workspace and authorize bulk rebuilds?
- How long may legacy shared tracks remain open? Who owns the drain dashboard
  and cleanup alerts, and when is an opt-in migration worth its data-copy cost?

## Alternatives considered

- **Keep one project machine and worktrees:** cheaper warm starts and shared
  caches, but preserves shared failure, port, filesystem and capacity boundaries.
- **One sandbox per thread:** defeats a track's durable workspace and multiplies
  clone cost; new conversations would not automatically see the same work.
- **Drop worktrees on the shared machine:** concurrent tracks would change the
  same checkout and files; it removes the existing separation without replacing it.
- **Omit `sandbox_id` but keep one project identity:** the mock reuses its box
  and the current code relies on identity reuse. It is not a fresh-box contract.
- **Migrate all open tracks immediately:** simpler steady state sooner, but
  risks dirty files, unpushed history and running services; coexistence is safer.
- **Infer ownership from the newest live thread:** repeats today's discovery
  failure when threads end or a newer conversation belongs to another sandbox.
