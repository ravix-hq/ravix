---
type: ADR
title: "Workspaces own repositories; a thread names who pays"
description: "Proposes workspaces as the tenant boundary, one project per repository within each workspace, explicit track visibility, and thread-starter billing gated on upstream credential isolation. Existing projects and billing remain compatible during a staged migration."
tags: [architecture, workspaces, access, billing, fountain]
status: draft
adr: "0009"
adr_status: "Proposed"
date: 2026-09-28
generated: { by: process:codex, at: 2026-09-28T00:26:15Z }
stale_after: 2026-10-28
---

# 0009 — Workspaces own repositories; a thread names who pays

**Status:** Proposed. A decision for the owner and Raunak to review, not an
implementation authorization. This PR changes documentation only. The phases
below describe dependencies for a later implementation plan; no migration,
authorization change or billing change ships with this ADR.

## Context

Raunak's 2026-09-27 feedback assumes a workspace Ravix does not yet model.
The supplied Linear brief is the source for these requirements; the issues
were not independently reachable from this track:

- **RAV-12:** identify repositories by fully qualified `owner/repository`,
  associate them with the workspace, and let members access repositories added
  by somebody else.
- **RAV-13:** exactly one project per repository within a workspace; adding it
  again opens the existing project.
- **RAV-10:** one workspace repository list when starting a track, without an
  organization/account selection step.
- **RAV-5:** proposed access even without individual GitHub repository access;
  alternatives hide the repository or show it without allowing track creation.
- **RAV-20:** tracks are not shared, shared with the workspace, or shared with
  specifically invited people.
- **RAV-17:** prompting spends the thread starter's subscription/API tokens,
  regardless of who prompts; project ownership does not select the payer.

RAV-23 is the workspace decision that ties these requests together. The
reported `ravix`, `ravix2` through `ravix10` projects on `ravix-hq/ravix` are
an example from the brief, not a production database inspection.

Current-code citations below refer to main at
`68eea3d07803af6851853af6e614f73f54df3b21`; `file:line` locations are pinned to
that revision, rather than assertions about a later deployment:

- A project belongs to a user and carries its repository, installation and
  provider identities (`lib/ravix/projects/project.ex:27`). Its changeset
  requires `user_id` and constrains only its primary key for uniqueness
  (`lib/ravix/projects/project.ex:62`); the original repository column has no
  unique constraint (`priv/repo/migrations/20260909074931_create_projects.exs:18`).
- `Access` exposes owner/member roles and owner/project/track discovery levels
  (`lib/ravix/accounts/access.ex:39`). Project members reach all tracks;
  track membership alone grants only that track
  (`lib/ravix/accounts/access.ex:94`, `lib/ravix/accounts/access.ex:145`).
  Promotion to project membership removes narrower track memberships
  (`lib/ravix/people.ex:29`).
- Threads have a track, runtime, model and conversation history, but no creator
  or payer field (`lib/ravix/tracks/thread.ex:10`).
- ADR 0006's text predates its implementation. Dedicated maintenance and
  conversation credential overrides are now built
  (`lib/ravix/tracks/sandbox/maintenance.ex:7`,
  `lib/ravix/tracks/sandbox/maintenance.ex:52`), with opens gated by the caller's
  `dedicated_open_user_ids` cohort (`lib/ravix/tracks.ex:554`,
  `lib/ravix/config.ex:4`) and maintenance gated by the project owner
  (`lib/ravix/projects/project.ex:70`). This is code evidence, not live provider verification.

This proposal would **amend [0005](0005-each-person-brings-their-own-agent.md)**:
thread-starter billing replaces project-owner billing only when the provider
conditions below are met. Its personal credential sets, revision invalidation
and prohibition on reading credential values remain. It would **amend
[0006](0006-a-sandbox-per-track.md)**'s owner-based billing and runtime eligibility,
while retaining one sandbox per track and at most one agent per runtime per
project. It would **amend [0008](0008-the-project-switcher.md)**'s discovery scope to
include workspaces while preserving narrow shares, personal sections and global
activity. It retains [0003](0003-cluster-and-transparent-deploys.md)'s cluster
and rolling-deploy rules. None of those ADR files is changed or superseded in
full by this proposal.

## Decision

### A workspace is the tenant, not a machine

A workspace is a named team with durable membership, projects and repository
connections. It is distinct from ADR 0006's use of “workspace” for a track's
working directory. A user may belong to several workspaces. Creating one makes
the creator its first owner; joining requires an accepted invitation. Personal
work starts in a personal workspace, using the same entity and access rules.

Use **owner, admin and member** roles. Owners transfer ownership, appoint
admins and authorize workspace deletion; the last owner cannot leave without
transfer or deletion. Admins manage invitations, repository connections and
project settings/secrets. Members discover workspace repositories, create tracks
and work on tracks whose visibility admits them. Administration does not
implicitly grant private transcript or terminal access. Provider cleanup may
still require an audited destructive administrative action; it is not a read
permission. Payer identity is separate from all three roles.

A workspace can connect **several GitHub App installations**, including several
organizations and personal accounts. An installation can be connected to several
workspaces only through an explicit, separately authorized connection; knowing
its id is not authority. Require both a workspace admin and verified authority
to connect that installation. Store one selected installation binding per
repository so clone credentials are unambiguous. Revocation suspends repository
operations; it never silently selects another installation or broadens access.
The UI lists connected repositories together and uses `owner/repository` to
remove naming ambiguity. There is no GitHub organization picker before a track.

### A project is a workspace's repository

For new workspace projects, require a repository and enforce a database unique
key on `(workspace_id, normalized_repo_full_name)`. Keep GitHub's display casing,
normalize comparison, and retain the stable GitHub repository id to reconcile
renames/transfers. A rename updates the name of the same project after checking
connection authority; a collision requires explicit resolution, never merging
by name alone. The same repository may have separate projects in different
workspaces, with separate members, secrets and billing consent.

Adding an already connected repository returns its existing project, including
concurrent adds through a unique constraint and conflict lookup. It does not
create another machine template or overwrite settings. `projects.user_id`
remains the legacy ownership field during compatibility; copy attribution to
`created_by_user_id`. In the new layout the creator is audit history, not the
project owner or payer. Workspace capabilities govern administration.

No new scratch projects enter the repository catalog. Existing repository-less
projects remain supported as legacy work; whether to offer a separate scratch
experience needs Raunak's call.

### Repository membership is not track visibility

Choose **RAV-5's proposed workspace access**: every workspace member may see
and create tracks in its repositories even without their own GitHub access.
The admin's installation connection delegates repository use to the workspace.
This fits RAV-12 and avoids presenting a shared catalog that many members cannot
use. Connection and invitation UI must explain that delegation. It does not
grant a personal GitHub permission or make every GitHub action possible as that
person; clone/push and actor attribution must use the authorized installation
contract. Repository revocation must stop new provider operations.

`Access` remains the single scoped door. Replace the inference that
`project_access` implies every track with separate project capabilities and a
track visibility predicate. Retain explicit track-only access for guests;
a guest is not silently made a workspace member. A share grants the named track
and the minimum project label needed to navigate it, never project settings,
the repository catalog, sibling tracks or track creation.

For new tracks, persist the creator and one of three modes:

- **Not shared (default):** only the creator may read/work on the track.
- **Workspace:** current workspace members may read/work on it.
- **Invited people:** the creator and specifically invited users may read/work
  on it; invitees may be guests without general workspace membership.

Only the creator controls these sharing modes; changing to Not shared revokes
invitations and outstanding links. Workspace administration alone does not
bypass visibility. Legacy tracks retain their existing project/member access
until explicitly converted; do not label them private. Currently “no individual
track members” is not private: project members already see every track
(`lib/ravix/people.ex:18`). Stop deleting explicit track membership on project
promotion in the new layout, since the two now answer different questions.

Private means Ravix transcript, files, terminal, preview and activity access is
restricted, not that commits pushed to the shared GitHub repository are secret.
Do not offer private mode on a legacy shared sandbox: a shell can reach sibling
worktrees (`lib/ravix/people.ex:44`). Require a dedicated sandbox first. Shared
project secrets are also available to code running in a permitted track; private
mode is not isolation from the provider operator or a promise to hide pushed work.

Workspace removal invalidates all that person's workspace-derived permissions
and explicit grants within it, including creator access, so removal cannot leave
an invisible guest route back in. Keep creator attribution. An intentional later
guest invitation is a new audited grant. Unowned private work remains inaccessible
until a reviewed recovery/retention policy applies; removal does not transfer its
billing obligation to an admin.

### A thread names the payer, but the provider must enforce it

**Choose thread-starter-pays as the target for new threads (RAV-17). It is not
feasible in full on today's documented Fountain/Codex contract.** Keep explicitly
labelled legacy owner-paid operation until it is. Workspace phases do not depend
on pretending this upstream work is done.

ADR 0005 rejected per-person conversation credentials because Codex permits only
one source on a machine. ADR 0006 separates tracks, not threads: Alice and Bob
can still start Codex threads on the same track and disk. A new track removes a
cross-track conflict, not this one. Agent cardinality is another constraint:
`RuntimeAgents` reserves by project/runtime and creates agents with the owner's
set (`lib/ravix/projects/runtime_agents.ex:89`). Base agent creation restricts
overrides (`lib/ravix/projects/machine.ex:556`). The newer dedicated path already
adds the owner's source to an agent allowlist without changing its default
(`lib/ravix/projects/runtime_agents.ex:155`) and sends a conversation override
(`lib/ravix/tracks/sandbox/maintenance.ex:52`, `lib/ravix/fountain.ex:418`).
That is useful plumbing, not support for concurrent different payers on one disk.

| Option | Fountain/Codex requirements | Decision |
|---|---|---|
| Project owner pays | Existing agent/set binding and one source per Codex disk suffice. Preserve a named legacy billing sponsor when workspace ownership replaces `user_id`; changing sponsor may require a new compatible disk. | Compatibility only; contradicts RAV-17 as a steady state. |
| Thread starter pays | Authorize an immutable source per conversation on the shared project/runtime agent; isolate concurrent Codex authentication per conversation on the same sandbox; enforce source/revision on attach, resume and prompt. | Target, blocked on the upstream isolation contract and verification. |
| Workspace pays | A workspace credential set can be the common source on its project agents/disks without relaxing Codex's single-source rule. Fountain needs durable workspace-managed credential ownership, administrator rotation/revocation and verified grant support if subscriptions are offered. Existing personal disks still cannot silently change source. | Plausible API-key alternative, but not RAV-17 and requires explicit workspace billing consent. |

Request upstream **conversation-scoped inference-source isolation on a persistent
sandbox**, including Codex auth storage/broker separation inaccessible to sibling
runtimes, concurrent distinct sources, resume behavior and revision revocation.
An allowlist alone or a different `CODEX_HOME` without enforced isolation is not
proof. Fountain must expose a version/capability gate and demonstrate two payers
on concurrent Codex threads, plus mixed Claude/Codex threads on one disk, without
cross-use or credential disclosure. Preserve the project/runtime agent limit;
do not solve this by allocating an agent per user or a sandbox per thread.
The current contract is assessed from Ravix and ADRs, not a live Fountain probe.

On enablement, record immutable `created_by_user_id`, `payer_user_id`, billing
policy and credential-set identity at thread creation, before launching. The
starter consents to paying for all collaborators' prompts. Queue delivery,
scheduled continuations, retries and replacement conversations keep that binding;
never charge whoever happened to trigger a retry. Runtime choices depend on that
payer's usable credentials. Revocation, expiry, removal or exhaustion pauses paid
work with a reason; no fallback to the owner, workspace or deployment account.
Credential revision changes require explicit recovery on the same payer's source,
not payer reassignment. Existing threads whose starter is unknown remain labelled
legacy sponsor-paid; do not infer a creator from the first transcript author.

Project/environment/vault inference secrets can override credential sets under
ADR 0005. Before enabling RAV-17, reject those override names for new-policy
launches, identify existing overrides without exposing values, and require their
removal or an explicitly legacy billing mode. Fountain must enforce the selected
source's precedence. Otherwise “the starter pays” is an unverifiable UI claim.
Infrastructure/sandbox costs remain a separate product question from inference.

### Compatibility is part of the model

Use expand/contract as required by `CLAUDE.md` (the
`AGENTS.md:90` contract) and ADR 0003: migrations run
while the previous release serves. Add nullable workspace, creator, visibility
and billing fields and new tables before any reader requires them. Backfill in
resumable batches; old writers may still insert nulls. Preserve old columns and
provider identities. Every release reads both legacy and workspace layouts, just
as it reads shared and dedicated sandboxes under ADR 0006. A missing workspace
means legacy authorization, never default-workspace access.

Create a personal workspace per existing user. Do **not** automatically make all
of an owner's collaborators members: that would reveal other repositories.
Projects with no duplicate and no access-broadening problem can move into that
workspace after owner approval. Until approval they retain legacy permissions.
Provide an inventory of members, repository connections and payer before moving;
workspace admission is an explicit wider grant.

Leave duplicate projects, including the reported Ravix/Ravix2 family, **alone**
in the legacy layout. Their tracks, threads, plans, shared/dedicated machines,
provider agents, vaults and secrets retain their ids and ownership. A nullable
workspace id keeps those rows outside the new unique key. Do not assign ten
conflicting rows to one workspace or union their secrets and memberships. The
owner selects at most one canonical project per repository for admission; others
stay visibly legacy and accept maintenance of existing work, but no new tracks
after cutover. New repository additions resolve to the canonical workspace
project. Branches and PRs can be referenced from new work without moving disks.
No automatic merge, archive, teardown or deletion is authorized by this ADR.
Any later consolidation requires a separate reviewed migration with an explicit
plan for plans, track URLs, membership, branch collisions, machines and secrets.

Keep dual writers for compatibility fields where their meaning is equivalent.
Where it is not (private visibility, multiple owners, non-owner payers), do not
encode new policy as old `user_id` semantics. First deploy readers and guards to
all instances and drain old workers; only then enable new-policy writes. An old
binary that cannot enforce the new access policy is not a safe rollback target.
Disabling the gate stops new writes, retains new-policy readers and leaves
resources intact. Contract only unused fields after all readers stop using them
and the rollback window has closed; removing legacy layout support itself needs
a later decision, not just a zero-row count.

### Membership follows the request across instances

Persist workspace memberships and revocations in Postgres. `Access` checks the
current user, workspace, project and track for every operation; a selected
workspace id is navigation state, not authority. Keep Store calls behind scoped
doors and ownership comments. Membership caches must never outlive a revocation
without a database check at the operation boundary.

Publish membership changes across the cluster to clear views promptly. On
connected events/messages, URL patches and async completions, recheck both session
expiry and membership before rendering or applying results. Fence async work by
workspace and membership generation; discard stale names, counts, files and
provider results. Unsubscribe removed viewers and revoke preview grants. A lost
PubSub notification must not preserve access. Reauthorize queued work at delivery
and fence in-flight provider side effects; cancellation cannot undo a prompt
already accepted, so record that outcome without replaying it.

Keep ADR 0008's minimal track-only project entries. Switcher search, Recent,
Inbox, Schedules and badges use the same visibility predicate, with no hidden
track counts. Workspace selection filters repository/project discovery; global
Inbox and Schedules remain across accessible workspaces and guest tracks.
Use ADR 0003's cluster naming/singleton rules for any new exclusive reconciler,
and durable database claims for backfill and billing operations. Node-local
state is not membership authority. Test two instances, removal during async work,
a revoked session and another workspace's ids before enabling the policy.

## Consequences

The repository catalog becomes a team resource, while private tracks require a
real change to authorization rather than a label on today's project membership.
Workspace administrators deliberately delegate GitHub installation access.
Existing duplicates survive, with some navigation complexity, because preserving
working disks and secrets is more important than making the catalog look clean.

Inference billing can lag workspace delivery. Until Fountain supplies isolation,
Ravix must say who actually pays and cannot claim RAV-17 complete. Accepting this
ADR does not confirm subscription-provider terms, live isolation or infrastructure
cost allocation. Those gates remain visible rather than becoming silent defaults.

## Phased implementation plan

These are candidate, separately shippable PR boundaries **after** owner/Raunak
review, not assigned implementation work in this docs PR.

1. **Contract and inventory (RAV-23, RAV-17).** Agree product calls below;
   inventory duplicate repositories, legacy access and secret overrides without
   reading secret values. Request and verify Fountain's isolation contract.
   Workspace work may proceed independently; billing enablement may not.
2. **Expand and dual readers (RAV-12/13).** Add workspace/membership/installation
   tables and nullable attribution/policy fields. Add the workspace repository
   unique constraint, resumable personal-workspace backfill and legacy fallback.
   Exercise old-writer rows, interrupted backfills and mixed-release reads.
   Keep existing authorization and writes active everywhere.
3. **Access boundaries before activation (RAV-5/20).** Implement workspace
   capabilities, guest grants, explicit track visibility, session/revocation
   guards and filtered discovery behind a gate. Test cross-tenant ids, private
   sibling names/counts, preview/terminal access, lost notifications and peer-node
   revocation. Deploy to every instance and drain incompatible queue workers
   before activating any new-policy row.
4. **Repository admission and navigation (RAV-12/13/10).** Ship explicit workspace
   creation/joining and authorized multi-installation connection, canonical
   project admission and atomic re-add lookup. Present one repository list for
   new tracks. Test concurrent adds, normalization, rename collisions, revoked
   installations and a member without personal GitHub access. Browser checks
   cover switcher, guest landing, global activity and mobile navigation.
5. **Sharing controls (RAV-20).** Enable the three modes only on dedicated tracks,
   with consent and explicit legacy conversion. Test member removal, share
   revocation, creator departure, old invite links and stale async results.
   Browser tests prove private tracks do not leak through search or badges.
6. **Thread payer binding (RAV-17).** Only after the upstream capability gate,
   add immutable starter/payer bindings and explicit legacy sponsor labels;
   enforce source selection, override rejection, consent and recovery. Verify
   concurrent distinct Codex payers and mixed runtimes live, plus retry, queue,
   payer removal and revision invalidation tests. Keep billing enablement
   separate from workspace enablement; no implicit payer migration.
7. **Observe and contract later.** Reconcile old-writer rows and pending provider
   operations; retain legacy duplicates and both sandbox layouts. Remove only
   fields unused by all deployed readers. Any duplicate merge or removal of dual
   readers requires its own decision and rollback evidence.

## Open questions for the team

- **Raunak and owner:** approve workspace-wide GitHub delegation (RAV-5), or
  choose hidden/read-only repositories for members without individual GitHub
  access? The proposed choice is full workspace use; changing it affects phases
  3 and 4 and requires a different authorization contract.
- **Raunak:** approve private-by-default tracks, admin access without private
  content access, external track guests, and removal revoking direct grants too?
  Who may recover or retain a departed creator's private work, and for how long?
- **Raunak:** is preserving duplicate projects as legacy acceptable, and which
  project is canonical for `ravix-hq/ravix`? Should scratch work remain a product
  feature outside repository projects?
- **Raunak and owner:** if upstream cannot isolate thread payers, wait for RAV-17
  or explicitly choose workspace-funded API keys? A one-payer-per-track rule is
  another product change, not an implementation of thread-starter-pays.
- **Fountain:** what capability/version proves per-conversation credential
  isolation on a shared Codex disk, including other-runtime guests and resumed
  conversations? Does selected-source precedence reject vault/env overrides?
  Who will run and record the live tests before enabling billing?
- **Owner:** what payer consent/spend limits, subscription-sharing terms and
  departure policy apply? Who pays sandbox compute/storage, separately from
  inference, and who may stop spending already in flight?
- **Raunak and owner:** what GitHub actor attribution should collaborators see
  for installation-authorized pushes, and what connection UX proves installation
  authority across multiple workspaces? Confirm rename/transfer recovery and
  installation revocation behavior before enabling shared repository access.

## Alternatives considered

- **Keep user-owned projects and deduplicate globally:** cannot represent teams
  with independent secrets/access, and makes one workspace's addition consume
  another workspace's repository identity.
- **Promote every existing collaborator into the owner's workspace:** broadens
  access to unrelated repositories without consent.
- **Call a track private while retaining project-wide track access:** contradicts
  RAV-20 and leaks both transcript metadata and shared-machine files.
- **Switch the project agent's credential before each prompt:** races concurrent
  threads, changes sibling behavior and does not lift Codex's disk restriction.
- **One sandbox or agent per payer/thread:** changes ADR 0006's shared track
  checkout or bounded project/runtime agent contract; not a hidden workaround.
