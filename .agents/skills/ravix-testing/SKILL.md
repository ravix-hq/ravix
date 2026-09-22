---
name: ravix-testing
description: Add regression tests or raise server, LiveView, and JavaScript-hook coverage in the Ravix repository. Use for behavior changes, bug fixes, and coverage work in this project.
---

Read the root AGENTS.md for the ownership and database invariants. Use
`coverage.exs`, `bunfig.toml`, and actual reports as the source of threshold values.

For a coverage task, run `mix test --cover` and read `cover/quality.json` plus
the relevant module HTML. The report excludes test support using BEAM source
paths and counts each executable source line once, as Mix does. Compare server,
web, and the two LiveView floors; the aggregate can hide an untested UI.

Choose the boundary that proves the behavior:

- Pure transformations: async ExUnit, including StreamData when broad input
  variation is the property. See transcript and names tests.
- Context persistence and authorization: DataCase, real factory changesets,
  and a second user/project/track. Mock external transports, not the context.
- LiveView: ConnCase and real session tokens. Exercise `form`, `element`,
  `render_hook`, and `render_async`; assert rendered outcomes or database state.
  A nested track view is found by `find_live_child(parent, "track-#{track.id}")`.
  Synchronous redirects can be returned from the render call; async redirects
  propagate through the parent. Assert the appropriate result.
- Provider streaming: local socket fixtures in `test/support/sprites_fake.ex`.
  Assert malformed/partial responses, timeouts, closure, and cleanup as well as
  successful payloads. Use message handshakes for concurrent work.
- Hooks: `bun test`, with Happy DOM fixtures in `assets/test/setup.js`. Dispatch
  keyboard/pointer/form events; assert drafts, uploads, focus, scroll, ARIA state,
  and server event payloads. Stub browser geometry/clipboard where the DOM fixture
  cannot implement them; this does not replace a real browser layout check.

Mimic modules are registered in `test/test_helper.exs`. Expectations are owned by
the test and inherited by supervised async work via caller tracking. Keep
`verify_on_exit!`; avoid global stubs. Test support must not inflate coverage.

After a regression is demonstrated, fix the cause and verify the focused test.
Finish with `mix precommit`, and with `mix precommit.release` and the container
smoke test if release/configuration changed. Raise sustainable coverage floors,
retaining failure-path assertions.
Document real-browser checks separately from DOM and LiveView tests; no single
coverage percentage proves integration or visual parity.

Real-browser checks live in `browser/`. Run `bun run test:browser` after
`MIX_ENV=prod mix assets.deploy`; install Chromium with
`bunx playwright install chromium` once. The harness owns its generated database
and mock processes. Never reuse a developer's server or change tests to accept
an unverified outcome. Assert transport reconnect, actual upload submission,
revocation, keyboard focus and accessibility in the running application.

Use `ExUnitProperties` for event sequences. See `lifecycle_properties_test.exs`
and the preview reconciler property. Synchronize pending work with messages and
verify every task settles before teardown. Suites using the fixture's fixed
preview ports belong to `group: :preview_ports`.

Guard changes must include negative evidence: `architecture_test.exs`, the
repository metadata tests, coverage-self-test.py, and the secret scanner's
`self-test` exercise rejection paths. A green command with invalid tests is not
successful validation; inspect the suite summary and fix setup failures.
