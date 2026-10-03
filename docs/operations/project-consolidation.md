# Consolidating repository projects

Repository consolidation is an explicit data cutover **after** the resource-aware
release has deployed everywhere. The schema migration expands the database only.
Never run apply from the release migration hook or while an older binary serves.
The pre-PMF assumption is a small projects table. The available local read found
zero projects in `ravix_dev`; production access was unavailable, so no production
row count or successful production consolidation is claimed.

1. Take a database backup. Inventory a workspace using the new release's repo-only
   entry point, which starts no web endpoint, scheduler, or reconciler:

   ```sh
   bin/ravix eval 'IO.inspect(Ravix.Release.consolidate_projects("WORKSPACE_ID"), limit: :infinity)'
   ```

   The result selects the existing non-duplicate repository project as canonical,
   with oldest creation time/ID breaking ties, and lists the donor project IDs.
   Scratch projects and projects in another workspace are excluded. Projects with
   no workspace require explicit workspace assignment first; a legacy duplicate's
   pointer is never treated as authorization to move across workspaces.

2. Stop all **Ravix application instances**, including their schedulers and
   reconcilers. Leave Fountain machines, conversations, shells, and worktrees
   running. Stopping Ravix removes stale in-memory project references without
   closing any track or stopping provider work. Keep the serving processes stopped
   until the cutover and checks finish.

3. Apply for each inventoried workspace:

   ```sh
   bin/ravix eval 'IO.inspect(Ravix.Release.consolidate_projects("WORKSPACE_ID", true), limit: :infinity)'
   ```

   Each workspace is one database transaction. A missing project, wrong workspace,
   different repository, deleting project, or archived project aborts
   the transaction. Archival state needs explicit review; consolidation never
   reactivates an archived donor's tracks. Resolve the reported condition explicitly and rerun. A
   completed workspace returns no duplicate groups on subsequent runs.

4. Inspect the database before restarting: each workspace/repository has one
   project; every previous track ID, conversation ID, workdir, branch, open/closed
   state, and dedicated sandbox ID remains. Donor project IDs now identify
   `project_resources` rows with their original agents, environments, vaults,
   settings and payer. Track `resource_id` selects that preserved machine. Check
   plan/schedule/routine/default counts and guest track access against the inventory.
   Restart only the resource-aware release, then verify an existing track from
   each original machine can read its conversation and worktree.

The operator makes no provider request. It preserves preview defaults and extra
runtime agents per resource, including identical runtime names, branch names and
slugs on different machines. Plans, routines and schedules retain the original
resource binding. Existing track grants remain; project guest memberships become
seats on the original project's visible tracks so guests gain no sibling tracks.
Original project invitation records and links remain scoped to those resources.
Workspace-sharing retirement rules still apply to those invitations. Canonical
invitations issued before the merge are limited to its original default resource;
new invitations intentionally share the canonical project. Existing section rows
remain. If one person placed both projects in different sidebar sections, the
canonical placement wins; otherwise the donor placement transfers. Closed-track
visibility preferences are combined.

The old runtime-agent and preview-default primary keys remain during rollout so
old writers' conflict targets work. Apply removes those keys inside the transaction;
resource-aware unique indexes already exist. This is the **contract boundary**:
do not restart the predecessor release afterward. A failed transaction rolls back
all moves and constraint changes. After a successful cutover, application rollback
requires a reviewed reverse data step or restoration of the pre-cutover backup;
blind schema rollback would destroy preserved machine identities.
