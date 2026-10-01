---
type: ADR
title: "The project switcher"
description: "Amended: a persistent project/track tree and keyboard quick-jump preserve scoped access, personal sections and cross-project activity."
tags: [navigation, projects, access]
status: stable
adr: "0008"
adr_status: "Accepted"
date: 2026-09-27
generated: { by: process:codex, at: 2026-09-27T00:47:18Z }
verified: { by: process:codex, at: 2026-09-27T00:47:18Z }
---

# 0008 — The project switcher

**Status:** Accepted and implemented in `WorkspaceLive`. The switcher uses the
existing asynchronous rail, scoped project/track reads and shared dialog focus
behavior. LiveView regressions cover membership, unread counts, revocation and
late results; browser coverage checks desktop and 500px navigation, keyboard
focus and accessibility. Sandbox lifecycle work remains independent.

## Amendment — 2026-09-28: persistent project and track tree

The owner reversed the rail decision in the 2026-09-28 design interview.
This amendment supersedes the switcher and rail portions below, addressing
RAV-11 and the navigation portion of RAV-9.

- Show every accessible project in the rail, grouped by the viewer's existing
  personal sections and order, with unsectioned projects last. Sections and
  projects collapse independently. Named sections use the viewer's saved section
  preferences across devices; project rows and the synthetic unsectioned group
  use local browser preferences. Neither is shared project state. Since
  RAV-127 a named section belongs to one of the viewer's workspaces, and the
  rail shows the current workspace's sections (ADR 0009, amended 2026-10-01).
- Each project appears once, with its unread badge and a new-track action only
  for viewers who may create tracks. Its expanded children are the open tracks
  that viewer can access. Highlight the current project and track. This tree
  replaces both the switcher control and the separate selected-project track list.
- Search becomes quick-jump over accessible projects and tracks, opened by
  Cmd-K on macOS, Ctrl-K elsewhere, or the visible Search button. Shortcuts
  preserve editing keys inside text fields and terminals. Arrow keys and Enter select results;
  Escape dismisses the shared dialog and returns focus to its trigger.
- Keep Home, Inbox with its global unread total, Schedules, Add a project and
  Manage sections reachable. Mobile uses the same tree in its navigation drawer;
  selecting a destination closes the drawer. Preserve Conversation/Files/Commands.

All original access, unread, asynchronous discovery, narrow-width and
accessibility requirements still apply, now to the tree and quick-jump.
Track-only access reveals only the viewer's tracks, including in badges and
search. Removing the last membership removes the project live; async results
must not restore revoked access. Discovery remains asynchronous with loading,
error and retry states; bulk track discovery uses the scoped Access path.
Private-track policy belongs to that same access boundary. Navigation must fit
the viewport without horizontal overflow and remain keyboard accessible.

The original decision below is retained as history; its rail and picker choices
are superseded by this amendment.

## Context

[Issue #262](https://github.com/ravix-hq/ravix/issues/262), decisions 5–7,
moves project navigation into a PostHog-style switcher. Decision 10 ships it
first, independently of the sandbox changes proposed in
[ADR 0006](0006-a-sandbox-per-track.md). Project and track membership are
different: sharing a track must not expose the rest of its project.
The current left rail lists projects in personal sections, with section
management in its Projects heading
([#190](https://github.com/ravix-hq/ravix/pull/190)). Home provides project
creation and a short Recent list. Narrow screens have workspace navigation
([#242](https://github.com/ravix-hq/ravix/pull/242)) and separate Conversation,
Files and Commands views ([#248](https://github.com/ravix-hq/ravix/pull/248)).

## Decision

Replace the always-open project list with a control showing the current
project name and opening a searchable list of the person's accessible
projects, each with its unread count. Selecting a project opens `/p/:project`;
existing project and track URLs keep their scope. On global pages the control
reads “Projects”, without implying that the page is filtered to a project.
Project discovery must retain the rail's asynchronous loading, loading/error
states and retry behavior (#221/#232); mount must not synchronously read the
project list.

- **Rail and sections:** keep the rail for global navigation and the selected
  project's navigation; remove its always-visible all-project tree. Move the
  personal sections, their order and placements into the switcher as list
  groups, with unsectioned projects last. Keep Manage sections and Add a
  project reachable there. Search filters accessible projects within those
  groups and hides empty groups; sections never confer access. Existing
  section preferences are retained, with no destructive data migration.
- **Track shares:** a project appears if the person has project access or
  belongs to at least one of its tracks. With only track access, opening the
  project lists only tracks that person belongs to. Neither search, sections,
  Recent nor badges may disclose other tracks' names, existence or counts.
  A project entry grants no project settings or track-creation permission.
  Removing the last track membership removes that project from discovery
  unless independent project membership remains.
- **Global activity:** Inbox, its total unread count and Schedules remain
  across all accessible projects, regardless of the selected project. Keep
  Inbox and Schedules reachable from navigation at every width. Each switcher
  badge uses the same unread definition as Inbox, restricted to that project
  and the viewer's accessible tracks. Selecting a project neither marks
  activity read nor filters global pages; hidden tracks contribute nothing.
- **Narrow widths:** expose the same switcher in the existing mobile workspace
  nav, without requiring the desktop rail to be opened. Its list fits within
  the viewport and scrolls vertically without horizontal page overflow. Keep
  search, sections and unread badges available. Selection closes the picker
  and any open mobile menu, then opens the selected project. Escape dismisses
  the picker and returns focus to its trigger; keyboard users can search and
  select projects. Preserve Home/Inbox active-page semantics from #242 and
  the track's Conversation/Files/Commands controls from #248.
- **Home and Recent:** `/home` stays a global landing page with project
  creation and its existing Recent shortcut list (up to eight projects in
  the existing order). Recent and the switcher navigate to the same project
  URLs and apply the same membership restrictions, including track-only
  projects. The switcher is the complete searchable list; Recent remains a
  shortcut, not a separate permission model or a new visit-history feature.

All reads go through `Ravix.Accounts.Access`. Connected events, URL patches
and async completions recheck session validity and membership; late results
must not restore revoked entries or counts. Implementation tests must cover
a track-only member seeing one shared track but no sibling names/counts,
loss of that membership, revoked sessions and another user's project/track
IDs, as well as global totals remaining unchanged by project selection.

## Consequences

Switching projects takes opening a picker, while the rail no longer grows
with every project. Personal organization survives in the picker. Restricted
projects need a useful landing view without assuming project membership.
Counts and discovery must share access rules across Home, navigation and
async updates. Browser tests should exercise selection, focus, overflow and
global navigation at phone widths as well as desktop. The implementation
changes no sandbox lifecycle.

## Alternatives considered

- **Keep the always-open project tree:** retains the navigation growth that
  decision 5 replaces.
- **Hide track-only projects or grant full project access:** the former makes
  shared tracks hard to find; the latter violates decision 6.
- **Filter Inbox and Schedules by the selected project:** violates decision 7
  and hides activity in other accessible projects.
- **Wait for dedicated sandboxes:** adds an unnecessary dependency contrary
  to decision 10.
