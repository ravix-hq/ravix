---
type: ADR
title: "Workspaces own repositories; a thread names who pays"
description: "Proposes workspaces as the tenant boundary, one project per repository within each workspace, explicit track visibility, and thread-starter billing with a single-payer restriction for Codex threads on one track. Records owner decisions, manual duplicate cleanup and a compatible staged migration."
tags: [architecture, workspaces, access, billing, fountain]
status: draft
adr: "0009"
adr_status: "Proposed"
date: 2026-09-28
generated: { by: process:codex, at: 2026-09-28T00:44:47Z }
stale_after: 2026-10-28
---

# 0009 — Workspaces own repositories; a thread names who pays

**Status:** Proposed. Incorporates the owner's decided workspace, access, billing
and duplicate-cleanup policy from the 2026-09-28 design interview. Remaining
product questions need Raunak's review; this is not implementation authorization.
This PR changes documentation only. The phases
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
an example from the brief, not a production database inspection. The owner's
2026-09-28 follow-up settles the policy choices below and supplies a source
review of `managoat/fountain`; upstream findings are attributed to that review,
not to a live provider test by this track.

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
its project-owner payer, owner-only agent credential binding and owner-runtime
selection decisions change for newly enabled starter-paid threads. Owner-paid
operation remains unchanged until that feature ships and for legacy threads.
Its personal credential sets, revision invalidation and prohibition on reading
credential values remain; the changed invalidation scope is specified below.
It would **amend
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
working directory. A user may belong to **several workspaces**, with an explicit
workspace switcher above project discovery. Creating one makes the creator its
first owner; joining requires an accepted invitation. Personal
work starts in a personal workspace, using the same entity and access rules.

Use **owner, admin and member** roles. Owners transfer ownership, appoint
admins and authorize workspace deletion; the last owner cannot leave without
transfer or deletion. Admins manage invitations, repository connections and
project settings/secrets. Members discover workspace repositories, create tracks
and work on tracks whose visibility admits them. Administration does not
implicitly grant private transcript or terminal access. Provider cleanup may
still require an audited destructive administrative action; it is not a read
permission. Payer identity is separate from all three roles.

A workspace connects **one or more GitHub App installations**, including several
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

**RAV-5 is decided: full access via the workspace.** Adding a repository gives
every member see/track/work access even without individual GitHub permission.
Ravix's GitHub App installation is the authority, as with Conductor or Vercel
teams. **A workspace invite grants effective access to every repository in that
workspace**, including repositories added later. Invitation creation and
acceptance must say this plainly, distinguish a workspace invite from a narrow
track invite, and show the workspace and current repository scope. Repository
connection UI must explain that all workspace members receive access. This fits
RAV-12 and avoids a shared catalog that members cannot use. It does not
grant a personal GitHub permission or make every GitHub action possible as that
person; clone/push and actor attribution must use the authorized installation
contract. Repository revocation must stop new provider operations.

`Access` remains the single scoped door. Replace the inference that
`project_access` implies every track with separate project capabilities and a
track visibility predicate. Retain explicit track-only access for guests;
a guest is not silently made a workspace member. A share grants the named track
and the minimum project label needed to navigate it, never project settings,
the repository catalog, sibling tracks or track creation.

The following private-track interpretation remains a recommendation for Raunak
to confirm under RAV-20, separate from the decided repository access policy.
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

### The thread starter pays as far as Fountain allows

**RAV-17 is decided: the thread starter pays, as far as Fountain allows. Until
it ships, the project owner keeps paying under ADR 0005 unchanged.** Claude
threads can bill different starters on one track today under the supplied
Fountain contract. Codex threads on that track must use one resolved source and
revision. Do not block Claude billing on a future Codex isolation feature.

The owner's 2026-09-28 Fountain source review establishes these contracts:

- Conversation creation accepts `inference_credential_id` in
  `apps/fountain/lib/fountain_web/schemas.ex` (approximately line 752), and
  pins that source across wakes. `Fountain.Conversations.resolve_inference_credential_id/3`
  (approximately line 3697) requires ownership by the calling Fountain account
  (`404 inference_credential_not_found`) and, when configured, admission by the
  agent's `allowed_inference_credential_ids` (`422 inference_credential_not_allowed`).
- Fountain ADR 0053, decision 6, excludes the credential from sandbox identity:
  conversations differing only in credential set share the machine, with the
  credential delivered as process environment. This permits distinct Claude
  payers; it is not a promise of hostile-process isolation on a shared disk.
- A shared Codex sandbox requires the **same resolved source and revision**;
  otherwise Fountain returns `409 codex_inference_conflict`. ADR 0006's threads
  share a sandbox, so separate tracks remove cross-track conflicts only.

**The calling account is Ravix's, not the person signed in with GitHub.**
`Config.fountain/0` supplies one server key (`lib/ravix/config.ex:169`);
`Inference` uses the common provider client (`lib/ravix/accounts/inference.ex:502`,
`lib/ravix/providers.ex:36`) and creates each person's named set on that account
(`lib/ravix/accounts/inference.ex:520`, `lib/ravix/accounts/inference.ex:548`).
Thus the sets Ravix creates for its users are owned by the same Fountain caller,
which satisfies upstream ownership without moving users' credentials. This
verifies the application path, not an inventory of production sets. A missing
or foreign-account set fails closed, with no fallback source.

**Choose an explicit allowlist, not unrestricted overrides.** Base agent creation
currently sets `allowed_inference_credential_ids: []`
(`lib/ravix/projects/machine.ex:556`). The newer runtime path creates an agent on
the owner's set and can add only the owner's source to its allowlist
(`lib/ravix/projects/runtime_agents.ex:104`,
`lib/ravix/projects/runtime_agents.ex:155`); it is not a member billing policy.
Ravix already sends a conversation override
(`lib/ravix/tracks/sandbox/maintenance.ex:52`, `lib/ravix/fountain.ex:418`).
Extend this to allow the workspace members' usable sets on each project/runtime
agent. Explicitly authorized track guests may contribute only their own usable
sets for threads they start in that project; this is not workspace membership.
Always select the source from the durable payer binding, never a browser-supplied
set id. Reconcile allowlists through serialized, durable project/runtime updates
so concurrent membership changes cannot overwrite one another. Recheck membership
at launch and delivery, and remove obsolete entries on revocation. An allowlist
is an extra provider boundary, not permission to charge any member arbitrarily.

Leaving overrides unrestricted avoids reconciliation and accommodates new members
immediately, but all users' sets share one Fountain account: a wrong set id could
then spend outside the workspace. Accept the reconciliation cost and fail closed
while a newly authorized set is not yet admitted. Keep at most one agent per
runtime per project; do not mutate its default before each prompt.

**For Codex, refuse a different starter on an already bound track.** The first
new-policy Codex thread atomically reserves the track sandbox generation's Codex
payer/source/revision before provider launch. Later Codex threads may be started
only by that same payer using the compatible source and revision. Other people
can still prompt the existing thread, billed to its starter. A different starter
sees: “Codex on this track uses another starter's credentials. Prompt an existing
thread, start a Claude thread with your own credentials, or start a new track.”
Do not create a billable conversation for a refused launch. The first Codex
starter need not be the track creator if the track began with Claude. Reconcile
ambiguous launches before releasing a reservation; concurrent first starts must
not both win. An existing Codex disk must adopt only a verified compatible
binding, never acquire a different source merely because its database field is
empty. Closing its last Codex thread does not clear the disk's source binding.

This keeps every admitted new-policy thread starter-paid and preserves the shared
checkout. Charging all Codex threads to the track starter would silently change
whose money a new thread spends; a guest sandbox per thread would break the
shared-disk contract and add lifecycle/copy costs. Fully independent Codex payers
on one track remain infeasible today. Removing that restriction later requires
upstream support for multiple resolved Codex sources/revisions on one persistent
sandbox, with safe concurrent authentication and resume behavior. That upstream
change is **not** a prerequisite for the restricted policy chosen here.

| Option | Fountain/Codex requirements | Decision |
|---|---|---|
| Project owner pays | Existing agent/set binding and one source per Codex disk suffice. Preserve the named legacy sponsor when workspace ownership replaces `user_id`. | Unchanged until starter billing ships; retained for legacy threads. |
| Thread starter pays | Existing conversation overrides plus member allowlists support Claude. Codex admission must enforce one payer/source/revision per track sandbox generation. Unrestricted Codex payers need upstream isolation changes. | Selected, with a clear refusal for a different Codex starter. |
| Workspace pays | A common workspace set on agents/disks fits Codex's single-source rule. Ravix would need workspace credential administration and consent; workspace subscription grants and source-change recovery need provider verification. | Not selected: it charges a workspace rather than the thread starter. |

Add a durable, immutable **`started_by` user-id column** to threads, which have
no creator today (`lib/ravix/tracks/thread.ex:10`). The default thread's starter
is the track creator; subsequent threads record the authenticated creator.
Persist `payer_user_id`, billing policy and credential-set identity before
launch. For new-policy threads the payer equals `started_by`; recording both
also describes legacy sponsor-paid threads without inventing a starter. The
starter consents to paying for all collaborators' prompts. Queue delivery,
scheduled continuations, retries, wakes and replacement conversations keep that
binding; never charge whoever triggers a retry. Runtime choices use that payer's
usable credentials, subject to the Codex restriction. Revocation, expiry, removal
or exhaustion pauses paid work with a reason; no fallback to owner, workspace or
deployment funds. Backfill known default-thread starters from track creators;
leave unknown historical starters null and keep their legacy owner-paid policy,
rather than inferring authorship from a transcript.

**ADR 0005 is amended in three decisions, not deleted:** a new-policy thread
spends its starter's set rather than its project owner's; project agents admit
authorized payer overrides rather than only the owner's source; and thread
runtime eligibility follows its payer rather than its owner. Lazy adoption of
owner credentials remains only for legacy billing. Personal sets, the reserved
empty house default, private credential writes and the agent connection UI remain.

**Any write to a credential set still ends conversations bound to its old
revision.** That now reaches collaborators working in the payer's threads in
other people's projects/workspaces, not just projects the payer owns. It also
invalidates legacy owner-paid threads started by other people on that same set.
Warn the payer about this scope before replacement/removal, notify affected collaborators
without exposing credentials or private thread names, pause queued prompts and
stop retrying refused old conversations. Retain thread/history and disk records.
Recovery keeps the same payer, creates a replacement conversation only when
compatible, and never silently rebills another person. Codex's revision rule
also prevents assuming that a new conversation fixes the old disk: verify
compatibility, or require an explicit rebuild/new track with dirty-work warnings.
Do not reset a shared track while sibling Claude threads are working.

Project/environment/vault inference secrets can override credential sets under
ADR 0005. Before enabling starter billing, reject those override names for
new-policy launches, identify existing overrides without exposing values, and
require removal or an explicitly legacy billing mode. Verify selected-source
precedence on the deployed Fountain. Infrastructure/sandbox costs remain a
separate product question from inference.

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

**Clean up existing duplicates by hand before migration.** The owner deletes
`ravix3` through `ravix10` as they drain; this docs PR does not perform those
deletions. Migration preflight verifies that cleanup, rather than automatically
deleting live resources. The remaining collision is the owner's `ravix2` and
Raunak's `ravix`, both on `ravix-hq/ravix`. Of these two, the later-created project
becomes a **legacy duplicate** and the earlier one is the canonical project on
admission to the shared workspace. Determine order from persisted creation
records, not names; ambiguous timestamps require owner resolution before cutover.
Personal workspaces still exist for both users; do not duplicate this shared
project into each personal workspace as a way to evade the collision.

No automatic merge of tracks, threads, plans, machines or secrets occurs. The
legacy duplicate retains its ids, URLs, access, sponsor, shared/dedicated disks,
agents and vaults for existing work, but cannot receive new tracks or be
re-created. Repository addition resolves to the canonical project. Store a
legacy-duplicate marker and canonical reference; preserve a reservation/alias
when the duplicate is eventually deleted so old creation paths cannot recreate
it. Only the reviewed migration can mark a legacy duplicate, never a client.
Unrelated workspaces may still independently add that repository as decided above.

Make the unique `(workspace_id, normalized_repo_full_name)` index partial for
non-legacy, non-null workspace/repository rows. This tolerates existing legacy
rows without admitting fresh duplicates to the catalog. Deploy compatible readers
and creation guards before enabling admission; old-writer rows are inventoried
and reconciled before cutover. Preserve legacy permissions until explicit
workspace admission, which requires consent from the affected owners. No union
of memberships or secrets is implied. Any later consolidation needs a separate
reviewed migration for plans, track URLs, branch collisions, machines and secrets.

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
Manual cleanup reduces the duplicate inventory before migration. The remaining
later-created duplicate survives as legacy work because its tracks, plans, disks
and secrets cannot safely be merged by repository name.

Owner-paid billing continues until starter billing ships. Claude can then use
per-thread payers; Codex admission stays narrower than unrestricted RAV-17. The
UI must name the actual payer and explain refused Codex starts. This ADR records
the supplied upstream contract, not a live verification or confirmation of
subscription-provider terms or infrastructure cost allocation.

## Phased implementation plan

These are candidate, separately shippable PR boundaries **after** owner/Raunak
review, not assigned implementation work in this docs PR.

1. **Contract and inventory (RAV-23, RAV-17).** Record the owner decisions and
   resolve remaining product calls below. Verify manual drain/deletion of
   `ravix3`–`ravix10`, identify the earlier canonical project in the remaining
   pair, and inventory legacy access/secret overrides without reading values.
   Verify the supplied Fountain override and Codex conflict contracts live.
   Workspace work and starter billing retain independent rollout gates.
2. **Expand and dual readers (RAV-12/13).** Add workspace/membership/installation
   tables and nullable attribution/policy fields. Add the workspace repository
   partial unique constraint, legacy-duplicate markers/reservations, resumable
   personal-workspace backfill and legacy fallback.
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
6. **Thread payer binding (RAV-17).** Add `started_by`, immutable payer bindings,
   explicit legacy sponsor labels and reconciled agent allowlists. Enforce
   Claude starter billing and atomic Codex source/revision reservations with
   refusal of a different starter. Verify distinct Claude payers, same-payer
   Codex threads, conflicting Codex starts and mixed runtimes live; test retry,
   queue, member/guest allowlists, revocation and cross-workspace revision
   invalidation. Enable after these contract checks, without waiting for
   unrestricted Codex isolation. Keep legacy billing and avoid implicit migration.
7. **Observe and contract later.** Reconcile old-writer rows and pending provider
   operations; retain legacy duplicates and both sandbox layouts. Remove only
   fields unused by all deployed readers. Any duplicate merge or removal of dual
   readers requires its own decision and rollback evidence.

## Open questions for the team

- **Raunak:** does “private track” (RAV-20) mean hidden from workspace members
  who are not invited, given that project members currently see every track
  (`lib/ravix/people.ex:18`)? The visibility section recommends that meaning;
  confirm the default, admin content access, external guests and removal of
  direct grants. Who may recover a departed creator's private work, and for how long?
- **Raunak:** should scratch work remain a product feature outside repository
  projects? Manual duplicate cleanup and the later-created legacy duplicate
  rule are decided, not open alternatives.
- **Raunak and owner — audit:** workspace invitations grant effective access to
  every repository. Which invitation, acceptance, repository-connection and
  removal events must be retained, for how long, and who can review/export them?
  How should admins see that a repo added later expands existing members' access?
- **Fountain verification:** who runs and records deployed override/allowlist,
  source precedence, Codex source/revision conflict and recovery checks? What
  recovery preserves dirty work after a Codex payer rotates credentials? A future
  upstream multi-source Codex contract could relax the refusal rule, but is not
  required for the decided restricted rollout.
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
- **Charge every Codex thread to the track starter:** changes the payer for a
  thread started by somebody else; refuse that new Codex thread instead.
- **Unrestricted agent credential overrides:** simpler membership updates, but
  the shared Fountain account makes a wrong set id a cross-workspace billing risk.
- **One sandbox or agent per payer/thread:** changes ADR 0006's shared track
  checkout or bounded project/runtime agent contract; not a hidden workaround.
