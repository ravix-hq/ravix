---
type: ADR
title: "Ravix is an Elixir application: Phoenix and LiveView on Fountain's stack and conventions"
description: "The Bun server and React SPA are replaced by one Phoenix application with LiveView pages, on Fountain's libraries and its engineering discipline; native previews, the Mac runner and the shared browser are scoped out and return as features later (#11, #12)."
tags: [architecture, stack, ui]
status: stable
adr: "0002"
adr_status: "Accepted"
date: 2026-09-09
generated: { by: claude-fable/5.1, at: 2026-09-09T08:10:00-04:00 }
stale_after: 2026-12-09
---

# 0002 — Ravix is an Elixir application

**Status:** Accepted, 2026-09-09; implemented in PR #13. The Phoenix backend,
LiveView pages, release and CI configuration replace the Bun/React application.
See [rewrite status](https://github.com/ravix-hq/ravix/blob/elixir-rewrite/docs/elixir-rewrite-status.md) for validation and the
remaining production deployment verification.
`stale_after` stands until the first Render deploy of the Elixir release
has been verified (#6), at which point set `verified` and remove it.

## Context

Ravix launched as a Bun server (about 9,600 lines of TypeScript) behind a
React SPA (about 10,400 lines), talking to Fountain's API, GitHub as a
GitHub App, and Sprites for the machine. It moved this week from a
Kubernetes cluster with SQLite to Render with Postgres (#1), and the move
exposed how much of the server was hand-rolled concurrency: serialised
transactions through `AsyncLocalStorage`, per-socket promise chains,
in-flight flags, a liveness cache. Those are the problems an OTP runtime
answers by construction.

Fountain, the platform Ravix is built on, is an Elixir application with an
established discipline: tenant scoping with the `_unsafe_` prefix rule, a
`precommit` gate (compile with warnings as errors, unused deps, format,
`credo --strict`, dialyzer, sobelow, a release assemble, tests), a coverage
gate in CI, ADRs as a validated OKF bundle, and test support on the SQL
sandbox. It also ships the libraries a Ravix server leans on hardest: the
Elixir SDK covers every Fountain call Ravix makes, and `managoat_acp` turns
ACP into the blocks a transcript renders. `docs/elixir-rewrite-brief.md` is
the exploration this decision came out of.

The original rewrite scope assumes no production users or data requiring
an import. Existing database tables can still be present, so the new
application must preserve them and avoid naming collisions.

## Decision

Ravix is one Phoenix application, `ravix`, with LiveView pages. Not an
umbrella: Ravix is a single OTP app with no extensions or libraries to
fence. The server and the UI are rewritten together, surface by surface,
and the JSON API the SPA spoke is retired rather than rebuilt: what remains
on HTTP is what is not a page (the OAuth callback, `/healthz`, the preview
gateway's control routes).

- **Data.** Ecto schemas and migrations for every table the SQLite-era
  `db.ts` created, with string primary keys as before. The
  new application stores them in the `ravix` PostgreSQL schema, preserving
  legacy `public` tables without importing their contents. An import is a
  deployment prerequisite if legacy records need to remain usable. Contexts are the
  API: `Ravix.Accounts`, `Ravix.Projects`, `Ravix.Tracks`, `Ravix.People`,
  `Ravix.PromptQueue`, `Ravix.Previews`. Every user-facing function takes
  the user; unscoped functions carry the `_unsafe_` prefix and sit adjacent
  to the scoped fetch that established ownership.
- **Fountain** through `fountain_sdk` behind `Ravix.Fountain`, with the
  SDK's injectable transport for tests. **GitHub** as a GitHub App through
  `Ravix.GitHub`: JOSE for the RS256 App JWT, Req for the calls,
  installation tokens cached until a minute before they expire.
  **Sprites** through `Ravix.Sprites`, a Req client for exec, services and
  the activity lease, and `Mint.WebSocket` for the `/proxy` tunnel.
- **Processes where the TypeScript had timers and maps.** The prompt queue
  is a GenServer over its table. Each track preview is a process under a
  DynamicSupervisor and Registry; the reconciler is its tick. The machine
  cache is ETS with a TTL. Fan-out is `Phoenix.PubSub` on a project topic;
  every LiveView re-checks access as it handles a message.
- **The preview gateway** is a Plug matched on Host before the router: a
  streaming reverse proxy and a WebSock relay onto the sprite tunnel. One
  port, as on Render.
- **The UI** is LiveView. `/p/:project/t/:track` stays the address and
  `handle_params` is the selection. The transcript is a stream of
  `managoat_acp` blocks; markdown renders on the server. Client code is
  confined to a written list of hooks: terminal keystrokes, composer paste
  and drop, transcript tail, panel drag, theme. Nothing else runs in the
  browser.
- **The discipline** is Fountain's, copied: the `precommit` alias, the CI
  shape with an 85% coverage gate, `DataCase` and `ConnCase` with a factory
  through real changesets, Mimic, no fire-and-forget `Task.async`, this
  ADR bundle with `okf validate` in CI. The audit trail and the docs gates
  are not adopted; Ravix has no manual and no audit surface yet.
- **Deployment does not change.** The same Render service and Postgres,
  the same environment variable names, a Dockerfile that builds a Phoenix
  release instead of a Bun bundle.

Three things are scoped out and return later as features: the native
preview experiment (Android and iOS through a Mac runner) and the `runner/`
daemon (#11), and the shared browser (#12). They were a fifth of the
server, carried their own wire protocols and the only client-side video
code, and never had a second user.

## Consequences

One language everywhere. The SDK, the sandbox adapters, the ACP blocks and
the markdown pipeline are maintained upstream, and the tenancy vocabulary
is Fountain's. The SPA's interaction tests stop being an acceptance test;
parity must be checked surface by surface against the TypeScript before
cutover. The retired application and its tests have been removed.

Ravix sets the JavaScript-hook precedent for both codebases; Fountain has
none. The hook list above is the policy, and adding to it is a decision,
not a convenience.

The `mock/` fake Fountain, GitHub and Sprites stays in TypeScript with the
two `shared/` files it imports, because it speaks HTTP and a dev server
does not care what wrote the fake. These local fixtures are the only remaining
TypeScript; production runs the Elixir release.

The three Sprites additions Ravix needs beyond `managoat_sandbox` (services,
the activity lease, the proxy tunnel) live in `Ravix.Sprites` until they
are contributed upstream.

## Alternatives considered

- **Keep TypeScript and port the discipline** — days of work for most of
  the discipline and none of the runtime; the concurrency problems stay
  hand-rolled.
- **Rewrite the server behind the existing API and keep the SPA** — two
  languages, an API contract to maintain, and the transcript parser and SSE
  hub kept alive only to serve a client that could be a LiveView.
- **Strangler with Phoenix in front of Bun** — two UIs for the whole
  transition and a second Render service, to protect users and data that
  do not exist yet.
- **An umbrella like Fountain's** — Fountain is an umbrella because of its
  extensions and libraries; Ravix has neither.
