# Elixir rewrite status

Implemented on `elixir-rewrite`, 2026-09-09, in [PR #13](https://github.com/ravix-hq/ravix/pull/13).
The application now runs as a Phoenix release with LiveView pages.

## Included

- Phoenix, Ecto schemas and migrations, runtime configuration, GitHub OAuth,
  expiring sessions, and scoped access checks on connected LiveViews.
- Project creation and repository selection, settings, secrets, preview
  defaults, rebuild/delete, membership management, and invites.
- Track creation from a blank worktree, branch, PR, or issue; streamed
  transcripts, prompt queue, image attachments, presence, rename/close,
  sharing, and pull request creation.
- Files, diffs, GitHub checks, terminal commands, vitals, and web previews
  with a supervised HTTP/WebSocket gateway and session-bound access tickets.
- PR #14’s IBM Plex and graphite/brass redesign, adapted to LiveView: landing,
  distinct sign-in/home/inbox pages, stacked project actions, and flatter chrome.
  Fonts are self-hosted; Ravix and Daylight retain readable muted text. See the
  [adaptation and screenshots](ui-polish/README.md).
- Search, responsive navigation, 22 themes, and the
  composer, terminal, transcript, panel resize, and theme browser hooks.
- The Bun server, React SPA, native runner, and their dependencies are removed.
  TypeScript remains only in local HTTP mocks and the two files they import.
- Coverage/static analysis gates, production assets/release assembly,
  Docker boot and database cutover smoke testing, and Render configuration.

## Database cutover

Elixir owns the `ravix` PostgreSQL schema. Existing Bun tables in `public`
are preserved, so migration neither collides with nor drops legacy tables.
The release creates its schema and runs migrations before boot; running
migrations again is harmless.

This is a fresh application dataset, consistent with the original rewrite
scope. It does not import legacy accounts, projects, or tracks. Users sign
in and create projects again. If legacy data must remain usable, an import
is required before production cutover; retaining tables is not an import.

## Validation

- The recovered backend's 19 test failures were resolved, including presence
  metadata, follower subscription/lifecycle, and transcript event handling.
- The final local suite passes: 739 tests, zero failures, 92.16% production-only coverage.
- The suite includes LiveView tests for scoped navigation, session expiry,
  membership revocation, project settings, prompt handling, files, changes,
  checks, previews, and fresh preview tickets.
- The full local gate runs warnings-as-errors compilation, dependency cleanup,
  formatting, strict Credo, Sobelow, dependency audit, Dialyzer, tests with
  a 90% production coverage floor and separate server/UI floors, assets, and release assembly.
- Dialyzer has seven narrowly matched filters for a `mint_web_socket` 1.0.5
  opaque type defect. The explanation and upstream source are in
  `.dialyzer_ignore.exs`; real socket tests cover the affected tunnel path.
- A browser exercised GitHub sign-in, repository selection, project and track
  creation, prompting, streamed output, files, and settings against the local
  Fountain/GitHub/Sprites mocks.
- `scripts/release-smoke.sh` boots the Docker release against disposable
  PostgreSQL 17, migrates twice, preserves an existing `public.users` row,
  and checks health, the landing page, and static assets.

See [engineering quality](engineering-quality.md) for the coverage ratchets,
28 browser-hook and repository-guard tests, recovery fixes, and contributor/agent tooling.

## Deployment follow-up

Production Render deployment and real Fountain/GitHub/Sprites integration
must be verified after merge (#6). Local mock and container checks do not
establish production credential or infrastructure readiness. Native previews
and the Mac runner remain deferred under #11; the shared browser remains
under #12. These exclusions are part of ADR 0002's accepted scope.
