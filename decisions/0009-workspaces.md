---
type: ADR
title: "Workspaces own repositories; a track's creator pays"
description: "Amended: workspaces own repository projects, sharing is workspace-only, and the track creator's credential, bound to the track's sandbox, pays for every thread and runtime on it, whoever prompts. Existing tracks stay owner-paid until backfilled or closed; a departed or disconnected creator's track fails prompts clearly rather than falling back. Workspace audit and departed-member private-track handling are deferred."
tags: [architecture, workspaces, access, billing, fountain]
status: stable
adr: "0009"
adr_status: "Accepted"
date: 2026-09-28
generated: { by: claude-opus/5.5, at: 2026-09-28T07:36:52Z }
stale_after: 2026-10-28
---

# 0009 — Workspaces own repositories; a track's creator pays

**Status:** Accepted, amended after Raunak's review and the owner's 2026-09-28
follow-up for RAV-23 and RAV-17. The workspace and billing policy below remains
implementation work; this amendment changes documentation only. No migration,
authorization change or billing change ships here.

## Amended 2026-09-28 — track creator billing and workspace-only sharing

Raunak clarified RAV-17: the track creator pays for every thread and runtime,
whoever prompts. Under ADR 0006 each track has its own sandbox, owned by its
creator, so every harness on that machine uses that creator's credentials.
This removes per-thread payer selection and the Codex different-starter refusal
rule. Legacy/shared-machine tracks keep project-owner billing until retired.

**Change record, 2026-09-28 (owner, after the RAV-17 clarification).** Raunak
wrote in Linear: “I meant ‘track’ not thread. If a user starts a track, their
subscription is used across that track. … When we create that sandbox, we put
that user's subscription/api on that sandbox.” The owner accepted this. The
billing section below records the resulting rules:
- the creator's credential is bound to the track's sandbox at creation;
- invitees and members prompting the track spend it;
- existing tracks stay owner-paid until backfilled or closed;
- a departed or disconnected creator's track refuses prompts rather than
  falling back to the owner.

The billing columns sit on `tracks`, not `threads` (phase 2).

The owner also replaced external guest invitations with workspace-member
selection and the track's ordinary URL, deferred the workspace audit log, and
deferred handling departed members' private tracks. The previously accepted
1-year audit log and 30-day orphan auto-close are dropped. #299's existing
owner-only orphan count and blind close remain unchanged. The decisions and
phases are amended inline below; repository identity, workspace scratch and
visibility defaults remain as accepted.

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
  specifically selected workspace members.
- **RAV-17:** as Raunak clarified, all inference on a track spends its creator's
  subscription/API tokens, across every thread and runtime, whoever prompts.

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

This decision **amends [0005](0005-each-person-brings-their-own-agent.md)**:
its project-owner payer, owner-only agent credential binding and owner-runtime
selection decisions change for newly enabled creator-paid dedicated tracks.
Project-owner billing remains unchanged until that feature ships and for
legacy/shared-machine tracks until retired.
Its personal credential sets, revision invalidation and prohibition on reading
credential values remain; the changed invalidation scope is specified below.
It **amends
[0006](0006-a-sandbox-per-track.md)**'s owner-based billing and runtime eligibility,
while retaining one sandbox per track and at most one agent per runtime per
project. It **amends [0008](0008-the-project-switcher.md)**'s discovery scope to
include workspaces while preserving narrow shares, personal sections and global
activity. Its pending `r2-sidebar-project-tree` amendment replaces the project
switcher with an always-open project → track sidebar tree and Cmd/Ctrl-K
quick-jump; this decision uses that navigation direction. It retains
[0003](0003-cluster-and-transparent-deploys.md)'s cluster and rolling-deploy rules. None of those ADR files is changed or superseded in
full by this decision.

## Decision

### Project-scope precursor already implemented

[PR #299](https://github.com/ravix-hq/ravix/pull/299) implemented project-scope
creator-controlled private tracks, removal that revokes private access and
stops the removed person's spending, and an owner-only orphan count and blind
close. These are the project-scope precursor of this workspace policy, not
workspace support. Keep #299's existing owner-only count and blind close as
they are; this amendment does not extend them to admins or add automatic
closure. Further departed-member private-track handling is deferred. The code
citations in Context describe the earlier pinned revision; their project-wide access assumptions predate #299.

### A workspace is the tenant, not a machine

A workspace is a named team with durable membership, projects and repository
connections. It is distinct from ADR 0006's use of “workspace” for a track's
working directory. A user may belong to **several workspaces**, with an explicit
workspace selector that scopes the project → track sidebar tree and quick-jump.
Creating one makes the creator its first owner; joining requires an accepted invitation. Personal
work starts in a personal workspace, using the same entity and access rules.

Use **owner, admin and member** roles. Owners transfer ownership, appoint
admins and authorize workspace deletion; the last owner cannot leave without
transfer or deletion. Admins manage invitations, repository connections and
project settings/secrets. Members discover workspace repositories, create tracks
and work on tracks whose visibility admits them. Administration does not
implicitly grant private transcript or terminal access. Provider cleanup may
still require an explicitly authorized destructive administrative action; it is not a read
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

For new workspace repository projects, require a repository and enforce a database unique
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
`created_by_user_id`. In the new layout the creator is attribution history, not the
project owner or payer. Workspace capabilities govern administration.

**Scratch projects remain supported as workspace scratch.** They sit outside
the repository catalog, are not deduplicated and never appear in the repository
picker. Give them their own sidebar group within the workspace, retaining
existing repository-less work through the compatible migration.

**2026-09-28 — planned replacement (Linear RAV-29):** a starter-repository
onboarding flow will let a new user start from a small public `ravix-hq` starter
repository. Workspace scratch remains as described above for now. When RAV-29
ships, stop offering new scratch projects; existing scratch projects keep working.

### Repository membership is not track visibility

**RAV-5 is decided: full access via the workspace.** Adding a repository gives
every member see/track/work access even without individual GitHub permission.
Ravix's GitHub App installation is the authority, as with Conductor or Vercel
teams. **A workspace invite grants effective access to every repository in that
workspace**, including repositories added later. Invitation creation and
acceptance must say this plainly, distinguish a workspace invite from a narrow
track share among existing members, and show the workspace and current
repository scope. Repository connection UI must explain that all workspace members receive access. This fits
RAV-12 and avoids a shared catalog that members cannot use. It does not
grant a personal GitHub permission or make every GitHub action possible as that
person; clone/push and actor attribution must use the authorized installation
contract. Repository revocation must stop new provider operations.

`Access` remains the single scoped door. Replace the inference that
`project_access` implies every track with separate project capabilities and a
track visibility predicate. **Sharing is workspace-only; no external guests.**
The creator picks existing workspace members using a Slack-style mention/picker;
each share is a permission row on the track. Workspace membership is necessary
but does not bypass private-track visibility. The track's own URL is the link:
there are no track invite links, link-revocation UI or guest logins in the
workspace model. Today's #299 track invite links remain until workspace
membership ships, then the member picker replaces them and the invite-link
flow is removed. Do not turn existing link holders into workspace members.

**RAV-20 visibility is decided in the owner's 2026-09-28 interview:** new
tracks default to visible to the project, becoming the workspace on workspace
admission. Private is an explicit opt-in and hides the track from everyone not
selected, including owners and admins. Persist the creator and one of three modes:

- **Project/workspace (default):** current project members, becoming current
  workspace members, may read/work on it.
- **Not shared (private opt-in):** only the creator may read/work on the track.
- **Selected workspace members:** the creator and specifically selected current
  workspace members may read/work on it.

Only the creator controls these sharing modes; changing to Not shared revokes
the selected-member permission rows. Workspace administration alone does not
bypass visibility. Legacy tracks retain their existing project/member access
until explicitly converted; do not label them private. At the pinned revision,
“no individual track members” was not private: project members saw every track
(`lib/ravix/people.ex:18`). Stop deleting explicit track membership on project
promotion in the new layout, since the two now answer different questions.

Private means Ravix transcript, files, terminal, preview and activity access is
restricted, not that commits pushed to the shared GitHub repository are secret.
**Private is dedicated-only; this is decided.** Do not offer private mode on a
legacy shared sandbox: a shell can reach sibling worktrees
(`lib/ravix/people.ex:44`). Require a dedicated sandbox first. Shared
project secrets are also available to code running in a permitted track; private
mode is not isolation from the provider operator or a promise to hide pushed work.

Workspace removal invalidates all that person's workspace-derived permissions
and explicit track grants within it, including creator access. Keep creator
attribution. Removal stops their spending; it never transfers their billing
obligation to an admin. A track URL cannot grant access without membership.

**Handling a departed member's private tracks is deferred.** Do not delete
those tracks as a new departure policy, and do not build admin recovery or
visibility. Drop the 30-day auto-close and any new retention deadline. #299's
existing owner-only orphan count and blind close stay as they are, including
their current scope; this amendment neither expands nor removes them. Further
handling, including tracks with remaining selected members, needs a later
product decision. Access and spending revocation still apply immediately.

### Audit and GitHub attribution

**No workspace audit log for now.** The previously accepted 1-year owner/admin
log, settings viewer and export are deferred; they are not rollout requirements.

**The Ravix GitHub App is the author and pushes commits.** Include a
`Co-authored-by` trailer for the thread starter; PRs name who started the track.
Use installation authority, with no per-user GitHub tokens.

**Later — 2026-09-28:** Raunak confirmed the attribution decision above. Once
there are many users, the intended direction is to attribute PRs to the track's
owner rather than the app. This is deliberately not for now: it requires a
per-user GitHub credential (a personal token or user-to-server grant), adding
onboarding friction. Decide that change in its own ADR when it becomes relevant.

### The track creator pays for every thread and runtime

**RAV-17: the track creator pays for all inference on a dedicated track, whoever
prompts.** When a track is created, its creator's inference credential is bound
to the track's sandbox. Every thread and every runtime—Claude, Codex and later Cursor—uses
the creator's credentials. Under ADR 0006 a track is its own sandbox, owned by
its creator; every harness on that machine logs in with the same person's
credentials. Starting a thread or delivering a collaborator's prompt never
selects a different subscription. Authorization still checks whoever acts, but
payer selection does not depend on that person or on the thread starter.

**Stated plainly: people selected on a track, and workspace members prompting
a workspace-visible track, spend the track creator's subscription**, on every
thread, including threads they start themselves. Someone who does not want to
spend the creator's subscription starts their own track.

One credential per track also satisfies Fountain's single Codex source and
revision per sandbox by construction. That is why the former Codex
single-payer-per-track restriction and different-starter refusal are dropped,
not deferred.

Until creator billing ships, existing project-owner billing stays active.
**Legacy/shared-machine tracks retain ADR 0005 project-owner billing until
retired.** Preserve their named sponsor rather than silently migrating a running
shared machine to a track creator's credentials. **Existing tracks, shared or
dedicated, that were created before creator billing** also keep the project
owner paying under ADR 0005 until one of two things happens:
- they are explicitly backfilled to their creator, which needs the creator's
  consent and a verified compatible credential on that sandbox;
- they are closed.

A null billing policy on a track means exactly this legacy owner-paid state;
readers never infer a creator payer from it.

**If the creator leaves or disconnects their subscription, prompting fails with
a clear error; the project owner does not take over.** Removal from the
workspace or project, a disconnected or revoked credential, expiry and
exhaustion all have the same effect:
- new prompts, queued deliveries, scheduled continuations and retries on the
  track are refused and paused with a reason naming the payer's state;
- no conversation is created on anyone else's credential.

A creator who reconnects resumes their own tracks. After a removal the track
stays readable to whoever its visibility still admits, and it can be closed as
today. Collaborators who want to continue start a track of their own.

This follows the RAV-27 orphan rules as they stand: removal revokes access and
stops the removed person's spending, never transferring the obligation to an
owner or admin. A departed creator's private track remains subject only to
#299's owner-only orphan count and blind close. Owner takeover was rejected
because it would silently charge someone who never consented and would break
that rule.

| Option | Requirements | Decision |
|---|---|---|
| Track creator pays | Bind the dedicated track and every harness/thread to its creator's credentials, with source and revision checks before launch/resume. | Selected: one creator owns the sandbox and pays for all its inference, regardless of runtime, thread starter or prompter. |
| Project owner pays | Preserve the existing agent/set binding and named legacy sponsor. | Retained for legacy/shared-machine tracks until retired and for existing operation until creator billing ships. |
| Thread starter pays | Select credentials per thread, reconcile multiple payers on a shared track disk and handle runtime authentication conflicts. | Not selected: a track's sandbox belongs to its creator; per-thread payer selection adds complexity and conflicts with every harness using the creator's credentials. |
| Workspace pays | Administer a common workspace inference credential set and consent. | Not selected for inference: the creator pays. Sandbox compute/storage remain billed to the workspace owner. |

Persist the track creator, billing policy, payer and credential-set binding
on the track row before launching paid work: `tracks.created_by` is the creator,
with nullable `tracks.payer_user_id` and `tracks.billing_policy`
(`legacy_owner | starter`) beside it, added in phase 2 and unwritten until
phase 6. Nothing about billing lives on `threads`. For new-policy tracks the
payer is the creator.
All threads, queue delivery, scheduled continuations, retries, wakes and
replacement conversations preserve that binding. Do not change the project's
agent default before each prompt. Shared project/runtime agents admit only
authorized creator credential overrides; serialize durable allowlist updates
and fail closed while a creator's set is not admitted. Never take a credential
set id from the browser or leave overrides unrestricted across Ravix's shared
Fountain account. Keep at most one agent per runtime per project.

Thread `started_by` remains attribution, including for `Co-authored-by`; it is
not a payer selector. Record the authenticated thread starter, use the track
creator for known default-thread attribution, and leave unknown historical
starters null rather than inferring authorship from transcripts. Changing who
starts a Claude or Codex thread does not change the payer and is not a reason
to refuse that thread. The former Codex single-payer reservation and
different-starter refusal policy are removed; the same creator's credentials
serve every runtime on the track.

**The creator consents when sharing the track:**
`Sharing this track means collaborators' prompts use your <subscription>.`
There are no spend caps yet. Name the creator as the payer to collaborators.
Sandbox compute and storage are billed to the workspace owner, separately from
inference. Runtime eligibility follows the creator's usable credentials.
Revocation, expiry, member removal or exhaustion pauses paid work with a reason,
as decided above; never fall back to the project owner, thread starter,
prompter, workspace or deployment funds.

**ADR 0005 is amended, not deleted:** dedicated tracks spend their creator's
set, project agents admit authorized creator overrides, and runtime eligibility
follows the track creator. Legacy billing keeps the project owner's set.
Personal credential sets, the reserved empty house default, private credential
writes and the agent connection UI remain.

Any credential-set write still ends conversations bound to its old revision,
including collaborators' threads on the creator's tracks and legacy work billed
to that set. Warn the payer about this scope, notify collaborators without
exposing credentials or private names, and pause queued work. Preserve history
and disks; recovery keeps the same payer. Verify source/revision compatibility
on resume, particularly for Codex disks after credential rotation. If a rebuild
or new track is needed, warn about dirty work and do not reset a track while
sibling threads are working. These are credential recovery checks, not a rule
refusing a different thread starter.

Before enabling creator billing, verify the deployed Fountain override,
allowlist, source precedence and revision/recovery contracts. Project/environment/
vault inference secrets can override credential sets under ADR 0005: reject
those override names for new-policy launches, inventory existing overrides
without reading values, and require removal or explicit legacy billing. The
owner's earlier Fountain source review is not a live provider verification.

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

Keep ADR 0008's minimal track-only project entries in the pending sidebar tree
and Cmd/Ctrl-K quick-jump amendment. The tree, quick-jump search, Recent, Inbox,
Schedules and badges use the same visibility predicate, with no hidden
track counts. Workspace selection filters repository/project discovery; global
Inbox and Schedules remain across accessible workspaces. Retain narrow legacy
track entries only while legacy access remains active; they do not grant workspace membership.
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

Project-owner billing continues until creator billing ships and remains on
legacy/shared-machine tracks and existing tracks until they are backfilled or
closed. A dedicated track then has one creator payer across every thread and
runtime, simplifying credential selection and making sharing consent explicit.
Collaborators spend the creator's subscription, and a creator's departure or
disconnection stops their tracks' inference rather than moving the bill. Workspace membership precedes the removal
of track invite links. Audit and departed-member private-track handling are
deferred, with #299's existing maintenance unchanged. This ADR records policy,
not live provider verification or confirmation of subscription-provider terms.

## Phased implementation plan

These are separately shippable PR boundaries under the accepted policy.
Implementation follows this amendment; this PR remains documentation only.

1. **Contract and inventory (RAV-23, RAV-17).** The owner decisions are
   recorded above. Verify manual drain/deletion of
   `ravix3`–`ravix10`, identify the earlier canonical project in the remaining
   pair, and inventory legacy access/secret overrides without reading values.
   Run and record deployed Fountain override/allowlist, source precedence,
   creator source/revision compatibility and dirty-work recovery checks before billing
   activation; confirm subscription-provider terms for the rollout.
   Workspace work and track-creator billing retain independent rollout gates.
2. **Expand and dual readers (RAV-12/13).** Add workspace/membership/installation
   tables and nullable attribution/policy fields, including the track billing
   fields (`tracks.payer_user_id`, `tracks.billing_policy`) and thread
   `started_by` attribution. Add the workspace repository
   partial unique constraint, legacy-duplicate markers/reservations, resumable
   personal-workspace backfill and legacy fallback.
   Exercise old-writer rows, interrupted backfills and mixed-release reads.
   Keep existing authorization and writes active everywhere.
3. **Access boundaries before activation (RAV-5/20).** Implement workspace
   capabilities, selected-member track permission rows, explicit visibility,
   session/revocation guards and filtered discovery behind a gate. Reject
   external users in workspace shares. Test cross-tenant ids, private sibling
   names/counts, preview/terminal access, lost notifications and peer-node
   revocation. Deploy to every instance and drain incompatible queue workers
   before activating any new-policy row.
4. **Repository admission and navigation (RAV-12/13/10).** Ship explicit workspace
   creation/joining and authorized multi-installation connection, canonical
   project admission and atomic re-add lookup. Present one repository list for
   new tracks and a separate workspace scratch sidebar group, outside repository
   deduplication and the picker. Attribute commits to the Ravix GitHub App with
   the thread starter's `Co-authored-by` trailer, and name the track starter in
   PRs; use no per-user GitHub tokens. Test concurrent adds, normalization,
   rename collisions, revoked installations and a member without personal
   GitHub access. Browser checks cover the sidebar tree, quick-jump, workspace
   selection, global activity and mobile navigation. No workspace audit log,
   settings viewer or export is included.
5. **Sharing controls after membership (RAV-20).** Enable the three modes only
   on dedicated tracks, keeping project/workspace visibility as the default,
   private opt-in, creator spend consent and explicit legacy conversion. Once
   workspace membership ships, replace #299's track invite links with the
   workspace-member mention/picker and track permission rows. Remove track
   invite links and link-revocation UI; use the track's own URL, with no guest
   logins. Old links must not bypass membership or admit external users after
   cutover; do not broaden legacy grants into workspace membership. Test member
   removal, permission-row removal, creator departure, old links and stale async
   results. Preserve #299's existing owner-only orphan count and blind close;
   add no departure-triggered deletion, auto-close, admin recovery or visibility.
   Browser tests prove private tracks do not leak through search or badges.
6. **Track creator payer binding (RAV-17).** Bind all inference on each dedicated
   track to its creator, for every thread and runtime regardless of who starts
   or prompts it. Keep thread-starter attribution separate from billing. Show
   creator sharing consent and payer labels; introduce no spend caps. Bill
   sandbox compute/storage to the workspace owner separately. Verify creator
   credentials across Claude, Codex and future harnesses, concurrent threads
   started by different members, retries, queue delivery, allowlist updates,
   revocation and credential rotation/recovery. There is no different-starter
   Codex refusal or per-thread payer selection. Refuse prompts with a clear
   error when the creator has left or disconnected, with no owner takeover.
   Backfill existing tracks to their creator only with consent and a verified
   compatible credential; otherwise they stay owner-paid until closed. Enable
   after provider contract checks; preserve project-owner billing on
   legacy/shared machines until retired.
7. **Observe and contract later.** Reconcile old-writer rows and pending provider
   operations; retain legacy duplicates and both sandbox layouts. Remove only
   fields unused by all deployed readers. Any duplicate merge or removal of dual
   readers requires its own decision and rollback evidence.

## Open questions

Departed-member private-track handling remains deferred, including tracks with
remaining members; no new deletion, recovery, admin visibility or retention
policy is authorized here. A workspace audit log is also deferred. Deployed
Fountain verification, credential rotation and dirty-work recovery checks,
subscription-provider terms, installation-authority UX and rename/transfer/
revocation checks remain implementation validation before their rollout gates.

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
- **Thread-starter billing:** requires per-thread credential selection and
  runtime conflict handling on a sandbox whose creator should pay throughout.
- **Unrestricted agent credential overrides:** simpler membership updates, but
  the shared Fountain account makes a wrong set id a cross-workspace billing risk.
- **One sandbox or agent per payer/thread:** changes ADR 0006's shared track
  checkout or bounded project/runtime agent contract; not a hidden workaround.
