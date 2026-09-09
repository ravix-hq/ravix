# Working on Ravix

Ravix is a Phoenix/LiveView application for working with coding agents on
Fountain-managed machines. Read the README for setup and ADR 0002 for scope.
The production app is Elixir; Bun is only for local HTTP mocks and DOM tests.
Native previews/the Mac runner (#11) and shared browser (#12) remain deferred.

## Start and verify

Versions are pinned in `.tool-versions`, CI, and Docker. Use PostgreSQL 17.

```sh
mix setup
bun install --frozen-lockfile
mix test test/ravix/tracks_test.exs       # focused server checks
mix test test/ravix_web/track_live_test.exs # focused LiveView checks
bun test                               # all five browser hooks, with coverage
mix test --cover                       # production-only coverage groups + HTML
mix precommit                          # complete local quality gate
```

`python3 scripts/dev-mock.py` starts Phoenix against the local mock; start
`bun run mock` separately. It requires no production credentials. See the
README for custom ports. Do not reuse a running process or database without
checking who owns it. Tests use `ravix_test` and SQL Sandbox transactions.

## Where changes belong

- `lib/ravix/`: scoped contexts, Ecto schemas, provider adapters, supervised
  processes. Contexts return tagged results and do not depend on web code.
- `lib/ravix_web/`: HTTP boundaries, LiveViews, components, and preview gateway.
  `WorkspaceLive` owns navigation/project forms; nested `TrackLive` owns the
  selected track. LiveView async work uses `start_async`/`handle_async`.
- `assets/js/hooks/`: browser-only interactions. Keep business state and provider
  credentials on the server. `assets/test/` tests actual DOM events and outcomes.
- `test/support/`: SQL sandbox cases, real changeset factories, scoped Mimic
  stubs, and local socket/provider fixtures. This code is excluded from coverage.
- `decisions/`: validated architectural decisions; `scripts/decisions-index.sh`
  regenerates their index. Historical rewrite briefs describe the old system.

## Invariants that matter

Every user-facing context call takes the current user and establishes scoped
access through `Ravix.Accounts.Access`. `_unsafe_*` calls need an adjacent
scoped fetch or an explicit internal sweep. Project membership and track
membership differ; a track share does not grant the entire project.

Mount-time authentication is insufficient. Connected events, messages, URL
patches, and async results must respect session expiry and membership removal.
Test a revoked session and another user's IDs when changing these boundaries.

Ecto uses the `ravix` PostgreSQL schema, including migration history. Legacy
Bun tables in `public` are preserved, not imported. Use the existing migration
aliases and release migration entry point; never point cleanup at `public`.

Use supervised processes for background work. `Task.async` is for tasks the
caller awaits; unlinked work belongs under `Ravix.TaskSupervisor`. Use monitors,
messages, or `render_async` to synchronize tests. A sleep is not proof of readiness.
A cache invalidation must still answer existing waiters and reject stale writes.

Keep atoms bounded at external boundaries, pass explicit provider configuration,
and return predictable tagged errors. Escape user/agent output; Markdown's raw
HTML boundary is centralized. Preview access tickets belong to the signed-in
session and are single-use. Do not place credentials in browser assigns or logs.

## Coverage and review

Coverage is a regression detector, not proof that a feature is correct. Test
observable behavior, real context persistence and access boundaries, and failure
recovery. Stub the external provider or the context boundary appropriate to the
layer; do not stub the function being tested. Prefer `async: true` for isolated
logic/database tests; use `async: false` when tests share named processes or DOM.

`coverage.exs` owns the production total and separate server, web, workspace,
and track floors. `cover/quality.json` and HTML identify gaps. `bunfig.toml`
owns the hook thresholds. Raise floors as coverage improves; do not lower floors,
exclude production logic, or add assertion-free calls to make a gate green.
Existing Dialyzer filters document an upstream Mint type defect; new warnings
must be investigated, not added to that exception list.

Run focused tests while editing, then the full applicable gates once before
publishing. Preserve failure evidence and investigate races rather than rerunning
until green. Explain behavior changes, validation, and remaining limitations in
PR descriptions. Do not merge or deploy merely because checks passed.

## Repository skills

- `.agents/skills/ravix-testing/SKILL.md`: choose fixtures and tests, inspect
  coverage gaps, and raise the server/UI gates without hiding untested behavior.
- `.agents/skills/ravix-elixir/SKILL.md`: implement scoped contexts and supervised
  LiveView/OTP work while preserving the project, track, and preview boundaries.

Claude uses the same guide and skills through symlinks, so edits do not drift.
Fountain at `~/dev/binarybourbon/fountain` is a useful reference for its ownership
contract, SQL sandbox conventions, and coverage accounting. It is an umbrella
operator console; do not copy its product scope, deployment rules, or LiveView
exclusions into this single application.
