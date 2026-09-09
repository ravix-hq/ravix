# Elixir rewrite status

This draft captures the work recovered on `elixir-rewrite` on 2026-09-09.
It is an incomplete migration and is not ready for deployment.

## Included

- Phoenix application, Ecto schemas and migrations, runtime configuration,
  authentication, sessions, and access controls.
- Projects, tracks, people, prompt queue, machine cache, presence, and
  transcript handling, with Fountain, GitHub, and Sprites clients.
- Preview supervision, reconciliation, HTTP gateway, and WebSocket relay.
- Shared web components, layouts, CSS, and browser hooks for the composer,
  terminal, transcript scrolling, panel resizing, and theme.
- ExUnit tests and fixtures, proposed Elixir CI and release deployment,
  and architecture decisions.

## Remaining before cutover

- Implement the LiveView pages and wire `/`, `/p/:project`, and
  `/p/:project/t/:track`; the workspace live session is currently empty.
- Resolve the build warning and failing tests, then complete static analysis,
  coverage, release boot, Docker, and end-to-end parity validation.
- Finish CI configuration: `coverage.exs` is not yet connected to `mix.exs`,
  and `mix precommit` does not yet run all the checks described in the ADR.
- Review the Dockerfile and Render changes before merging: they switch the
  deployment to the unfinished Phoenix application.
- Remove the old Bun/React application as part of the completed cutover and
  update the README. Native previews/runner and shared browser are deferred
  under issues #11 and #12.

## Validation at recovery

- `mix format --check-formatted`: passed after applying `mix format`.
- `MIX_ENV=test mix compile --warnings-as-errors`: failed because
  `test/support/tracks_boot.ex` calls undefined/private
  `Ravix.Presence.start_link/1`.
- `mix test`: 638 tests, 19 failures. Failures cover transcript page/event
  handling, presence metadata and lifecycle, follower shutdown, and track
  events/presence/file paths. This is one local run, not a flake assessment.
- Remaining CI/static analysis, coverage, release, and deployment checks
  have not been verified locally.
