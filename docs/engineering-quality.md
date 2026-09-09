# Engineering quality

The migration's first gate reported 86.99% coverage, including test support.
The production-only baseline was server 90.77%, web 73.35%, workspace LiveView
41.13%, and track LiveView 37.37%. The aggregate hid the new UI's gaps.

The strengthened local gate passes 707 ExUnit tests and 18 DOM tests:

| Area | Production baseline | Current coverage | Enforced floor |
|---|---:|---:|---:|
| Server | 90.77% | 92.26% | 92% |
| Web | 73.35% | 91.20% | 90% |
| Workspace LiveView | 41.13% | 92.91% | 92% |
| Track LiveView | 37.37% | 93.43% | 92% |
| Browser hooks | Not measured | 99.09% lines / 98.57% functions | 90% per file |

Overall production line coverage is 91.98%. The old 86.99% aggregate included
test support and is therefore not directly comparable to this production total.

## Gates

`coverage.exs` now requires 90% production coverage overall, server 92%, web 90%,
and each LiveView 92%. Test fixtures and dynamically copied Mimic modules do not
inflate the total. Only the existing application/repository/release/telemetry
bootstrap exclusions remain. Application migrations and release boot are also
exercised by the real container smoke test.

`Ravix.Coverage` delegates instrumentation and HTML output to Mix's native
coverage tool. It selects production modules by their BEAM source paths, then
counts each executable line once, dropping line zero and merging clause hits
with logical OR. This follows Fountain's `scripts/coverage-gate.exs` and the
[Elixir 1.19 coverage implementation](https://github.com/elixir-lang/elixir/blob/v1.19.5/lib/mix/lib/mix/tasks/test.coverage.ex).
A regression test verifies clause deduplication. Empty groups fail closed.
Reports are written to `cover/quality.json` and the standard `cover/*.html`.

`bun test` exercises DOM behavior of every file in `assets/js/hooks`, including
hooks without a test import. Each file requires 90% line and function coverage;
LCOV goes to `cover/hooks/`. Happy DOM is development-only, following
[Bun's DOM testing guidance](https://bun.sh/docs/test/dom). Tests dispatch actual
DOM events and verify draft retention, upload notifications, keyboard/IME
behavior, focus/history, theme state, accessible resize controls, scroll position,
and copy feedback. Geometry and clipboard are controlled at the browser API
boundary because a DOM fixture has no rendering engine.

The CI jobs upload both coverage reports, including on failure. `mix precommit`
runs the Elixir and hook gates together with compile, format, Credo, Sobelow,
Hex retirement audit, Dialyzer, assets, and release assembly. It needs `bun install
--frozen-lockfile` once after cloning. Versions are pinned in `.tool-versions`.

## Tests and fixes

New LiveView tests cover repository selection, all track origins, provisioning
failures, secrets, preview defaults, destructive-action confirmation, membership
and invite persistence, rename, terminal output/cwd/errors, vitals, queue actions,
preview tickets/configuration, PR creation, closure, presence, and transcript
refreshes. SQL Sandbox and real session/access checks remain active; external
provider work is stubbed at the relevant boundary.

Server regressions cover cache reset with an in-flight caller, loader crashes,
preview process restart, startup failures, malformed HTTP/chunk framing, stalled
bodies, zero-length bodies, and trailers. The tests exposed and fixed cache-reset
waiters being lost, dead preview PIDs returned during registry cleanup, and
provider lookup errors leaving preview startup unsettled.

Legacy test code that manufactured missing application modules has been removed.
Mimic registration is centralized in `test/test_helper.exs`, and preview fixtures
assert the application's supervision tree instead of silently adding children.

## Agent workflow

`AGENTS.md` is the single guide; `CLAUDE.md` links to it. Two focused skills live
in `.agents/skills` and are shared with Claude through `.claude/skills`:
`ravix-testing` and `ravix-elixir`. Their files validate with the skill creator's
frontmatter validator. They identify local test commands, ownership boundaries,
async work rules, fixture selection, coverage reports, and deployment scope.

The reference was Fountain's contributor guide, coverage configuration, and
coverage script at `~/dev/binarybourbon/fountain`. Ravix adopts the relevant
ownership, sandbox, supervision, and coverage conventions. It does not copy
Fountain's umbrella layout, product rules, or exclusions of untested LiveViews.

## Limits and ratcheting

Line coverage does not measure all branches, and HEEx generation can attribute
many rendered outcomes to one executable line. A high number is not a substitute
for assertions about the rendered behavior and authorization. DOM tests do not
establish visual layout or full LiveSocket integration; use a real browser for
changes involving those boundaries. Provider mocks and local sockets do not
verify production credentials or infrastructure.

When a behavior changes, add a regression at the layer that can observe it,
inspect the affected report, and raise the applicable floor when the measured
improvement is sustainable. Do not lower a floor or exclude runtime logic to
make a build pass. Retain failure evidence and investigate races before retrying.
