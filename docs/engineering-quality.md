# Engineering quality

The migration's first gate reported 86.99% coverage, including test support.
The production-only baseline was server 90.77%, web 73.35%, workspace LiveView
41.13%, and track LiveView 37.37%. The aggregate hid the new UI's gaps.

The strengthened local gate passes 739 ExUnit tests, four generated properties, and 28 DOM/guard tests:

| Area | Production baseline | Current coverage | Enforced floor |
|---|---:|---:|---:|
| Server | 90.77% | 92.16% | 92% |
| Web | 73.35% | 91.92% | 90% |
| Workspace LiveView | 41.13% | 94.01% | 92% |
| Track LiveView | 37.37% | 92.54% | 92% |
| Browser hooks | Not measured | 99.10% lines / 98.67% functions | 90% per file |

Overall production line coverage is 92.16%. The old 86.99% aggregate included
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

## Required guards

Nine checks form the merge gate: test, static analysis, browser hooks, browser
smoke, release assembles and boots, Docker release and cutover, okf validate,
secret scan, and dependency audit. The decisions workflow runs on every PR so
required checks cannot remain pending because of a path filter. Branch protection
requires these checks on an up-to-date PR, including for administrators, and
disables force pushes and branch deletion. Reviews remain a human choice; no
approval count is imposed.

The browser job uses Chromium against the production configuration, actual
LiveSocket traffic, and local Fountain/GitHub/Sprites transports. Each invocation
owns fresh provider processes and a uniquely named database that is dropped on
exit. It refuses occupied ports. No test-only authentication route is installed.
The flows cover OAuth, repository/project/track creation, streamed output, image
submission, draft retention across transport reconnect, session revocation in a
second tab, keyboard resizing/dialog focus, and axe checks in Ravix and Daylight.
The UI adaptation from PR #14 adds local font-loading checks, scratch-project
creation, recent-project navigation, theme persistence, and screenshots of public
and workspace pages at desktop, tablet, and mobile widths.
The deployed Switchyard comparison adds project disclosure, advanced track options,
terminal draft retention across dock changes, parent dialogs from a nested track,
and scrollable settings checks.
Failure traces and screenshots are retained for seven days; retries are disabled.

Run locally after `bunx playwright install chromium`:

```sh
MIX_ENV=prod mix assets.deploy
bun run test:browser
```

The browser regressions found and fixed faint text with insufficient contrast,
resize ARIA attributes lost after server patches, the sidebar handle measuring
its neighbouring main panel, lost drafts on reconnect, and dialog focus not
returning to its trigger. DOM regressions supplement these browser checks.

The architecture Credo check rejects web dependencies from contexts, any
mention of a `Ravix.<Context>.Store` from `lib/ravix_web/`, cross-context row
access without an ownership explanation, and unsupervised production
Task/spawn work. `Ravix.Application` is the composition-root exception to the
web dependency rule. Static checks cover explicit calls and aliases, not arbitrary
runtime metaprogramming; ownership comments are review aids, not access proofs.
The preview gateway adapter now lives in the web layer, and the agent context
returns tagged errors. A request-level regression also exposed and fixed the
missing `/api/tracks/:track_id/preview/agent` route; it uses the existing scoped
bearer capability without accepting browser cookies as authorization.

Generated properties exercise cache completions across invalidated generations,
terminal queue states under late responses and restart recovery, overlapping
transcript snapshots with out-of-order replay, and repeated preview intent
changes while startup is blocked. Delayed LiveView responses are rejected after
session revocation or track closure. Preview suites share the `:preview_ports`
ExUnit group because their deterministic provider names share uniqueness keys;
other groups remain parallel.

Secret scanning uses checksum-pinned Gitleaks with redacted output, including a
negative synthetic-token fixture. Five exact historical fingerprints cover
public development keys, PEM-header assertions, and the RFC WebSocket example
nonce; whole files are not exempted. Dependabot proposes weekly Mix, Bun, Docker,
and Actions updates. Weekly and manually triggered audits check Hex and Bun
advisories even when the app has not changed. CI actions use immutable commits.

`bun scripts/quality.mjs` validates runtime pins, immutable Actions, workflow
triggers, and agent guides/skills; negative fixtures are part of `bun test`.
`python3 scripts/coverage-self-test.py` creates disposable projects to prove low
production totals, low groups, empty groups, and a newly untested hook all fail.
It runs in CI and `mix precommit`. Custom Credo tests verify positive/negative
examples and that the real configuration enables the check.
