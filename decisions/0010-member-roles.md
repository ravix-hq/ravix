---
type: ADR
title: "Read, Write and Admin roles on track and project memberships"
description: "Each track seat and project membership carries a role -- Read (see the transcript and preview), Write (also prompt, use the machine, commit) or Admin (also manage people) -- enforced at the context doors in Ravix.Accounts.Access, added expand/contract with NULL read as Write. Unbuilt: roles on workspace grants and pending invitations, a per-track general-access role, and the contract migration."
tags: [access, sharing, people, migrations]
status: stable
adr: "0010"
adr_status: "Accepted"
date: 2026-09-30
generated: { by: process:claude, at: 2026-09-30T12:00:00Z }
stale_after: 2026-11-30
---

# 0010 — Read, Write and Admin roles on track and project memberships

**Status:** Accepted (RAV-53). The expand migration, the role-aware
`Ravix.Accounts.Access`, enforcement at the doors listed under *What is
enforced*, the people dialog's role menu and its copy link ship with this
ADR. Not yet built, and named again under *Not yet built*: roles on
workspace grants (ADR 0009) and on pending invitations, a per-track
general-access role, and the contract migration.

## Context

Until now everybody let into a track or a project could do everything a
member can: read it, prompt its agent, run commands on its machine, commit
and push. `Ravix.Accounts.Access` answered one question -- `role :: :owner |
:member` -- and "member" meant all of that. The only line was the owner's:
the project's controls (settings, packages, secrets, rebuild, delete)
resolve through `project_of/2` and nobody else reaches them.

That leaves no way to show somebody the work without handing them the
machine, and no way to let a trusted collaborator manage the people without
making them the owner. Conductor's Share popover (the comparison in RAV-53)
has per-person Admin / Read / Write, a general-access row with a role, and a
link anybody with access can copy. Related: RAV-19 (ask-only access), RAV-20
(sharing modes), RAV-27 (private-track follow-ups).

Two facts constrain the answer. **Project membership and track membership
differ** (AGENTS.md): a track share must never grant the project. And
**migrations run while the previous release still serves** (ADR 0003), so
a new column is written by one release and ignored by the other for the
length of a deploy.

## Decision

### The three roles

A role is carried by a **grant** -- a track seat (`track_members`) or a
project membership (`project_members`) -- and says what the holder may do
through it. The roles widen:

- **Read** — open the track; read its transcript, files, diff and checks;
  open a preview somebody else started; read and write comments (they go
  to people, never to the agent); copy the link; leave.
- **Write** — Read, and use the agent and the machine: send prompts (web,
  MCP `send_prompt`, schedules), start threads, stop a turn, retry, change
  the thread's model, run terminal commands, start/stop/configure the
  preview, open a pull request (the agent commits and pushes on Write's
  behalf), retry refused prompts, and on a project cut tracks and
  rename or close the ones they cut.
- **Admin** — Write, and manage the people on the unit the grant is for:
  invite, remove, change roles, and mint or revoke invite links.

**The owner is always admin** of the project and of every track they can
see, with one exception kept from #299: a *private* track is run by its
creator, and there the owner holds only what their own seat gives them.
A private track's creator is always its admin. Neither the owner's nor a
creator's role can be changed, and nobody changes their own role.

**Admin is not the machine.** The project's controls -- settings, packages,
secrets, rebuild, delete -- stay the owner's alone, through `project_of/2`,
because they spend the owner's credentials (ADR 0005). "Settings" an admin
manages are the sharing settings: who is in, at which role, and the invite
links. Changing that line is a separate decision.

A row with no role (`NULL`) is **Write**, which is exactly what every member
could do before this ADR.

### Project membership versus track membership

Each grant applies to its own unit and no further:

- A **track seat's** role applies to that one track. A track admin manages
  that track's people and nothing on the project: they cannot invite to the
  project, see its other tracks, or cut tracks. A track share never grants
  the project.
- A **project membership's** role applies to the project (cutting tracks
  needs Write; managing the project's people needs Admin) and to every
  **project-visible** track. It says nothing about a private track, which
  admits only its creator and its seats, whatever the project role.
- On a track reached by more than one grant, the **highest** applies: a
  project Read member with a Write seat on a project-visible track writes
  there. (Promotion to the project already deletes narrower seats on
  project-visible tracks, so this is the rare case.)
- Workspace grants (ADR 0009 -- live workspace membership, permission rows
  on private tracks) predate roles and work as **Write**.

`Access.track_access/2` and `project_access/2` compute this as `level`
beside the existing `role` (which still says owner-or-member, i.e. how
somebody got in). `track_access/3`, `thread_access/4` and
`project_access/3` take the level required and answer
`{:error, {:forbidden, message}}` for somebody who can see the unit but
lacks the role -- not found stays reserved for people who cannot see it.

### General access with a role

A track's general access is its visibility. "Everyone in this project"
admits every project member at **their own project role**: there is no
separate, weaker role for "everyone". "Only people I invite" (private)
turns general access off; the creator and the track's seats remain, each at
its role.

A per-track general-access role -- "everyone in the project may *read*
this track", capping project members below their project role on one
track -- is the natural next step and is **not built**. When it is, it must
cap only; it never lifts anybody above their own grant, and it never
applies to the owner, the creator or a track admin.

### The copy link

Every person who can open the people dialog gets the unit's own address
(`/p/:project/t/:track`, or `/p/:project`) to copy, always. It is not an
invitation and grants nothing: somebody without access who follows it gets
the not found a stranger gets. Invite links (`/j/:token`) are unchanged and
remain admin-only; their URL is still shown once.

### What is enforced

Enforcement is at the context door, so every caller inherits it: LiveView
events, async results, MCP tools, schedules and the prompt queue all reach
the same function. Mount-time checks decide nothing.

- `Tracks.prompt/3`, `start_thread/4`, `retry/3`, `interrupt/3`,
  `set_model/4`, `resume_billing/3`, `open_pull/3` — Write.
- `Tracks.rename/3`, `close/3`, `close_finished/3`, `close_info/2`,
  `rebuild_machine/3`, `set_visibility/3` — Write, on top of their existing
  owner/creator rules.
- `Tracks.open/4` and `Schedules.create/3` — Write on the project.
- `Terminal.exec/3` — Write.
- `Previews.open/3` starts a preview for Write and only opens a running one
  for Read; `run`, `restart`, `stop`, `save_config` — Write.
- `PromptQueue.retry/3` — Write. Delivery (`PromptQueue.Server`) re-checks
  Write for the sender before posting, so a prompt queued before a demotion
  is cancelled, as a removal's would be.
- MCP `send_prompt` (`Tooling.Tasks.send/5`), `create_track`,
  `close_track`, `retry_setup` — Write.
- `People.add/3`, `remove/3` (somebody else), links, `set_role/4`;
  `People.add_project/3`, `remove_project/3`, project links,
  `set_project_role/4` — Admin.

A role change publishes `:people` on the project's hub, as removal does.
Open pages re-read their access on it (`RavixWeb.Live.Guard`), the track
page redraws its composer from the new level, and an open people dialog
reloads.

### Migration: expand, then contract

1. **Expand (this release).** `ALTER TABLE track_members/project_members
   ADD role text` -- nullable, no default -- with `CHECK (role IS NULL OR
   role IN ('read','write','admin'))`. The previous release does not know
   the column and inserts rows without it; `NULL` reads as Write, which is
   what that release means by a member. This release also writes nothing
   by default: only a role change stores a value.
2. **Deploy window.** While both releases serve, an instance of the old one
   ignores roles, so a member demoted to Read can still write through a
   session it serves until it drains. Demotions made during a deploy take
   full effect when it completes. Rolling back past this release after
   roles have been set restores Write to everybody; roll forward instead.
3. **Contract (a later release, once no instance of the previous one is
   serving).** Backfill `UPDATE ... SET role = 'write' WHERE role IS NULL`,
   then `ALTER COLUMN role SET DEFAULT 'write', SET NOT NULL`. The code's
   `NULL -> :write` reading can then go. Not built.

## Consequences

- A person can be shown the work -- transcript, diff, preview -- without
  being handed a shell, the agent or the owner's subscription.
- Owners can delegate people management (Admin) without delegating the
  machine's controls, which stay theirs.
- `track_access/2` costs up to two more single-row reads for a non-owner
  (the seat's role and the project membership's). It is already called on
  every guarded message; the reads are keyed on primary keys.
- A read-only member still sees the "Ask agent" mode, disabled, with the
  reason; comments stay open to them.
- Admin on a private track seat can now manage its people alongside the
  creator; before, only the creator could.

## Not yet built

- Roles on workspace grants and permission rows (ADR 0009), and in its
  Share dialog; those grants work as Write.
- Roles on pending invitations: an invitation is claimed at Write, and the
  role is set once the person has signed in.
- A per-track general-access role (see above).
- Hiding every Write-only control from a read-only member's page: the
  composer, Stop and the model menu are disabled; the other controls
  (terminal, preview start, rename/close, new thread, pull request) are
  refused by the server with the role's sentence.
- Plans and plan assignment (which can start work on a track) have not
  been reviewed for roles.
- The contract migration.
- A keyboard shortcut for Copy link; ⌘⇧C / Ctrl+Shift+C is taken by the
  browser's element inspector.

## Alternatives considered

- **Replace `role :: :owner | :member` with the three roles.** Dozens of call
  sites match on `:owner`, and "how did you get in" and "what may you do"
  are different questions; a second field keeps both readable.
- **One role per person per project, applied to every track.** Breaks the
  rule that a track share does not grant the project, and cannot express
  "Read on this one branch".
- **Store the role in a new table.** Two joins on the hottest door for no
  gain; the grant row already exists and is what removal deletes.
- **Backfill in the expand migration.** Harmless for the rows, but the old
  release keeps inserting `NULL` during the deploy, so the code must read
  `NULL` as Write anyway; the backfill belongs with the NOT NULL.
