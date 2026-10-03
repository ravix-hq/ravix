# Working on Ravix

Ravix is a Phoenix/LiveView application for working with coding agents on
Fountain-managed machines. Read the README for setup and ADR 0002 for scope.
The production app is Elixir; Bun is only for local HTTP mocks and DOM tests.
Native previews/the Mac runner (#11) and shared browser (#12) remain deferred.

## Instruction hierarchy

This file is the single guide. It holds product context, engineering
philosophy, local commands, and the cross-cutting rules every change answers
to. The two skills in `.agents/skills/` hold narrower, task-shaped guidance:
`ravix-elixir` for contexts, LiveView, and OTP work; `ravix-testing` for
fixtures and coverage. `decisions/` holds validated architectural decisions,
and `docs/` holds human-facing orientation and measured reports.

Move broad guidance upward into this file and keep narrow guidance in the
skill or ADR that governs it. Do not repeat a rule in a skill unless the skill
adds a concrete example, an exception, or a sharper boundary. Dense editing
rules belong here; `README.md` and `docs/` stay orientation for people.

## Session learning

If a session needed a reusable correction, add it to the narrowest place that
would have prevented the miss: this file for a cross-cutting rule, a skill for
a task-shaped one, an ADR when the decision itself was wrong, or a guard in
`credo/checks/`, `scripts/`, or the test suite when a check can enforce what a
sentence can only ask for. Prefer the enforceable form. Skip one-off,
speculative, or already-covered lessons.

## Start and verify

Versions are pinned in `.tool-versions`, CI, and Docker. Use PostgreSQL 17.

```sh
mix setup
bun install --frozen-lockfile
mix test test/ravix/tracks_test.exs       # focused server checks
mix test test/ravix_web/track_live_test.exs # focused LiveView checks
bun test                               # browser hooks and repository guard fixtures
mix test --cover                       # production-only coverage groups + HTML
mix precommit                          # local analysis, tests, guard probes
mix precommit.release                  # production assets and release, as CI's release job
bunx playwright install chromium       # once per Playwright upgrade
bun run test:browser                    # deprecated browser smoke placeholder
bun run test:browser:workspace-access   # deprecated browser smoke placeholder
python3 scripts/secrets.py git .        # redacted history scan
```

Do not add or update tests for exact UI copy, literal strings, component
markup/classes, labels/tooltips, themes, layout, or other visual cosmetics.

`python3 scripts/dev-mock.py` starts Phoenix against the local mock; start
`bun run mock` separately. It requires no production credentials. See the
README for custom ports. Do not reuse a running process or database without
checking who owns it. Tests use `ravix_test` and SQL Sandbox transactions.

## Engineering philosophy

We favor simple, explicit programs built around clear data, readable flow, and
measured tradeoffs. In this repository that means:

- **Clear and explicit beats clever and implicit.** Prefer obvious control
  flow, explicit return shapes, and boring names over convenience wrappers,
  macros, or dynamic dispatch. A `with` chain a reader follows top to bottom
  beats a shorter one they must decode.
- **Data dominates.** Model the right domain state first — the schema, the
  changeset, the struct a process holds. Once the data is shaped well, context
  functions and LiveView assigns become straightforward.
- **Simple data structures and simple algorithms first.** Do not add
  generalized machinery, behaviours, registries, ETS, or a process until the
  concrete use case proves it removes real complexity. A function is cheaper
  than a process, and a process is cheaper than a supervised, globally named,
  cluster-aware one.
- **Flat is better than nested.** Keep the path from a LiveView event through
  a context to the database easy to scan. Split a private function when it
  names a step, not to hide code.
- **Sparse is better than dense.** Leave room for names, typespecs, and small
  intermediate values. Do not compress meaningful product behavior into one
  piped expression or a catch-all helper.
- **Small interfaces are stronger interfaces.** A context's public function
  exposes the real contract its callers need. Avoid paired functions differing
  only by a convenience return value; `Tracks.follow/3` returns a pid because
  a caller must monitor it, not because a second variant read better.
- **Errors and edge cases are values.** Return tagged results callers can
  match on, with bounded atoms at external boundaries. Do not encode
  meaningful state in a log line, a raised string, or a side effect.
- **Special cases should justify themselves.** Keep provider quirks, legacy
  `public`-schema facts, and already-shipped-client behavior narrow, named,
  tested, and close to the boundary that requires them.
- **A little copying is better than a little dependency.** Prefer a local,
  direct implementation over a new Hex package or an abstraction for a narrow
  path. Every dependency is also a pin, an audit, and a weekly update PR.
- **Fit the whole system, not just the local diff.** Before merging, name the
  other surfaces the change touches: LiveViews and their nested children, the
  API and preview gateway, agent tooling, browser hooks, the second BEAM
  instance (ADR 0003), a migration running while the previous release still
  serves, and already-shipped clients. A clean module that strips another
  layer's context, breaks the second instance, or exists only in unit tests
  that skip the real supervision tree is not done.

## Scale-calibrated engineering

This section binds every agent writing code, designing a system, or reviewing
either one.

Ravix is pre-product-market-fit. The best design at our scale is frequently
*not* the design a best-practices answer produces, because that answer is
calibrated for a scale we do not have. **A recommendation is not finished
until it names the scale it assumes.** Stage — proxied by user count, row
count in the table being changed, and request rate on the path being changed
— is an input to the decision, not context to mention after the fact. Few
users means we pivot fast and keep the code cheap to throw away; many users
means we move slowly and carry migration and compatibility weight. Know which
regime the change is in before recommending anything.

This cuts in two directions, and both are mandatory:

- **Do not import complexity we have not earned.** Caching layers, queues,
  read replicas, partitioning, generalized behaviours, retry/backoff
  machinery, and extra coordination all spend readability now to buy headroom
  later. At our row counts and request rates that trade is usually a loss.
  Name the scale where it starts paying off.
- **Do not skip what is fundamental at any scale.** Scoped access and the
  `Store` boundary, session expiry and membership revocation on connected
  events, credential handling, expand/contract migrations against real rows,
  additive changes for already-shipped clients, tagged explicit interfaces,
  and tests of observable behavior do not depend on user count. Small scale is
  never a reason to weaken them, and "early" is not a review defense for them.
  Everything under *Invariants that matter* is in this category without
  exception.

It is acceptable to leave a known edge case unhandled when the simple behavior
is safe enough. Document the accepted failure mode beside the simplifying
code, and add a `TODO` with an explicit **WHEN** clause naming the observed
invocation count, affected-user count, rate, volume, or incident threshold
that justifies the larger design. Do not build that design before the
threshold is crossed, and do not write a vague trigger such as "when we
scale."

### No AI slop

**Complexity that no scale justifies is a defect, not a style preference.**
Most code here is model-authored, and the characteristic failure of
model-authored code is not being wrong — it is being *bigger than the
problem*: layers, guards, options, and abstractions added because they
pattern-match "production quality," none of which any user, caller, or row
count asked for. That is slop. Review it as a bug class with a name, and
delete it.

Slop as it actually shows up in this repository:

- A context function, helper, or component with one caller that only forwards
  its arguments. Inline it.
- A behaviour, protocol, or adapter module with exactly one implementation and
  no test that substitutes another.
- A GenServer, Registry entry, `Ravix.Cluster.via/2` name, or
  `Ravix.Cluster.Singleton` wrapper for work a function call already does, or
  for a process that may safely run once per instance.
- `try/rescue`, a `case` arm, or a `with` else branch for a failure that
  cannot happen or is not handled — especially one that logs and continues,
  turning a bug into a silent wrong answer.
- Fallback chains, retries, or defaults whose non-happy path no test and no
  production request has ever executed.
- Hand-rolled validation after a changeset already validated it, or
  hand-rolled SQL that Ecto already writes.
- Config keys, options, and `opts` parameters no call site sets.
- A `# ownership:` comment standing in for an access check. The comment names
  the door a caller already went through; it does not open one.
- Comments and docstrings that restate the signature or the typespec. A
  comment earns its place by explaining *why*.
- Compatibility shims for a contract that never shipped, and migration paths
  for data that does not exist. The legacy `public` tables are a real fact; an
  imagined older client is not.
- Tests that assert a Mimic expectation was called, or assert on markup, copy,
  classes, or themes, instead of asserting observable behavior.
- Caching, ETS, or memoization on a path whose cost was never measured, and
  assertion-free calls added to move a coverage floor.

Two rules follow:

1. **The fix for slop is deletion, not refactoring.** When behavior is wrong
   because of an extra layer, remove the layer rather than adding a rule on
   top of it. The smallest diff that delivers the product behavior is the
   target.
2. **Slop is a violation; missing scalability machinery usually is not.**
   These grade in opposite directions, and conflating them is what produces
   reviews that add complexity while claiming rigor. Unjustified complexity in
   the diff → must fix now. "This will not hold at scale" with no measurement
   → deferred. If you cannot name the caller, row count, request rate, or
   incident that requires a piece of code, that code does not ship.

### Measure before you recommend

Ravix is deployed and instrumented (ADR 0004). Read it instead of guessing,
and pick the read that matches the question:

| Question | Where to get it |
|---|---|
| How many users, projects, or tracks? How many rows in the table I am changing? | the production Postgres read through the `render-ravix` MCP server |
| How often is this path called? How slow? Which span dominates? | Honeycomb, dataset `ravix`, environment `prod` — the traces `Ravix.Trace` exports |
| Is it erroring? Did the release boot? What did the deploy do? | Render service logs and events (`render-ravix`) |
| What do people actually do in the product? | PostHog — the server-side events `Ravix.Analytics` captures |
| Is the local shape even the same as production's? | `ravix_dev` locally; never point a query, cleanup, or migration at `public` |

One such read costs seconds. A wrong scale assumption costs either machinery
nobody needed or an outage. Read first. Production data is real user data —
read only what the current task needs, and remember that `Ravix.Redact` exists
because a span attribute and an event property are the same hazard.

Cite numbers with their provenance. A fresh read ("Render logs, last 24h: 41
requests to this route, 0 5xx") outranks a remembered one, and a remembered
number carries its date so the reader can judge staleness. If the number
needed to decide does not exist yet, the cheapest correct move is usually to
add the span, event, or counter now and defer the design decision until it has
data — not to build for the guess.

### The shape of a proposal or a finding

Every design, complexity, or performance recommendation — including complexity
a change *adds* — states three things:

1. **Measured now.** The current figure from a real read: rows, requests per
   day, p95, error rate, affected users. "This runs on every mount" is a code
   fact, not a scale measurement.
2. **Breaks when.** The concrete threshold at which the simple version stops
   being safe enough, in the same units. This is the `TODO ... WHEN` clause.
3. **Cheapest change that holds until then.** Usually smaller than the
   textbook answer. If it is not smaller, say why the threshold is already
   close.

A recommendation missing (1) and (2) is a preference. Label it as one or drop
it. Findings sort into "must fix now" — a fundamental, slop in the diff, or a
threshold already crossed — and "document and defer" for everything else.
State which. No measured figure and threshold for a new layer means it is
slop; leave it out.

If production is unreachable or the metric does not exist, do not block and do
not invent a number: say the read failed, ship the simple implementation,
write the assumed scale in one line beside the code, and add the
`TODO ... WHEN` threshold that would justify the larger design. A documented
accepted failure mode beats an unmeasured mitigation.

## Where changes belong

- `lib/ravix/`: scoped contexts, Ecto schemas, provider adapters, supervised
  processes. Contexts return tagged results and do not depend on web code.
- `lib/ravix_web/`: HTTP boundaries, LiveViews, components, and preview gateway.
  `WorkspaceLive` owns navigation/project forms; nested `TrackLive` owns the
  selected track; `OnboardingLive` owns the first visit (`/welcome`) and is
  never a gate; `Live.AgentPanel` is the agent step, Settings › Agents and
  the reconnect dialog, one component so they cannot drift. LiveView async
  work uses `start_async`/`handle_async`.
- `assets/js/hooks/`: browser-only interactions. Keep business state and provider
  credentials on the server. `assets/test/` tests actual DOM events and outcomes.
- `test/support/`: SQL sandbox cases, real changeset factories, scoped Mimic
  stubs, and local socket/provider fixtures. This code is excluded from coverage.
- `decisions/`: validated architectural decisions; `scripts/decisions-index.sh`
  regenerates their index. Historical rewrite briefs describe the old system.

## Invariants that matter

Every user-facing context call takes the current user and establishes scoped
access through `Ravix.Accounts.Access`. Row access with no user in hand lives
in a `Ravix.<Context>.Store`, never beside the scoped functions: a page may
not name one at all, and a context reaching into another's writes a
`# ownership:` comment naming the door it already went through. The same
comment is required of a `Repo` call that names another context's schema,
because otherwise the unchecked path is the shorter one to write. Id-only
process orchestration that is not row access (`Ravix.Previews.Lifecycle`)
is held to the same two rules as a `Store`. Project
membership and track membership differ; a track share does not grant the
entire project.

A project spends its *owner's* agent subscription whoever is working in it
(ADR 0005). The value lives in a Fountain credential set and is never stored,
assigned, logged or read back here; `Ravix.Accounts.Inference` is the only
writer, and any write to a set ends the conversations already running on it.

Mount-time authentication is insufficient. Connected events, messages, URL
patches, and async results must respect session expiry and membership removal.
Test a revoked session and another user's IDs when changing these boundaries.

Ecto uses the `ravix` PostgreSQL schema, including migration history. Legacy
Bun tables in `public` are preserved, not imported. Use the existing migration
aliases and release migration entry point; never point cleanup at `public`.

Use supervised processes for production work. Use `Task.Supervisor.async_nolink`
with an explicit await when a caller owns the result; background work belongs
under `Ravix.TaskSupervisor`. Bare `Task.async` is allowed in tests only. Use monitors,
messages, or `render_async` to synchronize tests. A sleep is not proof of readiness.
A cache invalidation must still answer existing waiters and reject stale writes.

The app runs on more than one instance (ADR 0003), so ask of any new process
whether a second instance may run its own. A per-track process that must not
exist twice is named through `Ravix.Cluster.via/2` (`:global`) and supervised
node-locally; recurring work that must not run twice goes behind
`Ravix.Cluster.Singleton`; work that is merely cheaper once, like the prompt
queue's sweep, stays on every instance and stays idempotent. Nothing is handed
over when an instance leaves: `:global` releases the name and the database is
the state. A process holding something a caller still needs must therefore be
monitored *by* that caller, which is why `Tracks.follow/3` returns a pid.
Migrations run while the previous release is still serving, so they are
expand/contract: add before reading, stop reading before dropping.

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

Do not write a test whose main assertion is that a feature does not exist, a
field is absent, or an internal stub was called with one exact shape. Those
freeze today's implementation instead of protecting product behavior. A
negative assertion is right when absence is the contract: a denied caller, a
revoked session, a credential kept out of assigns and logs, a single-use
ticket already spent, a stale result rejected. Otherwise assert the positive
behavior — the row persisted, the rendered outcome, the tagged error a caller
can match, the process that settled.

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

The custom Credo check in `credo/checks/architecture.ex` enforces web/context
separation, supervision, the `Store` boundary above, and `# ownership: ...`
explanations on cross-context row access. Application startup is the one composition-root exception. Tests prove
both rejection and acceptance; comments alone do not establish authorization.
Preview suites sharing the fixture's `s1`/`s2` ports use `group: :preview_ports`
to avoid cross-transaction uniqueness waits while unrelated suites run in parallel.

Cluster behavior that only a second BEAM can show lives in
`test/ravix/cluster/distribution_test.exs`, which starts real peer nodes running
the whole application; peer-side code goes in `test/support` because a test
module's beam never reaches a peer. Keep to one peer at a time and wait for it to
leave `Node.list/0`, or `:global` starts disconnecting nodes to protect itself.
The file is tagged `:distributed` and a plain `mix test` leaves it out; CI and
`mix precommit` pass `--include distributed`, as a focused run of it must.

Browser tests use production configuration and create/drop only a generated
`ravix_browser_*` database. Ports 4103/8893/8894 must be free; no existing server
is reused. `BROWSER_DATABASE_SERVER` can change local PostgreSQL credentials.
Keep browser tests under `browser/` and retain failure traces. Axe covers the
default theme; manual checks still matter for other themes and assistive devices.

An icon-only control is `<.icon_button>`, or carries `aria-label` and
`data-tip` itself: `data-tip` is the app's one tooltip (`assets/js/tooltip.js`,
with `data-tip-kbd="Mod+K"` for a shortcut), not the native `title`. Focus
rings are `:focus-visible` only, and none after pointer input
(`assets/js/focus_ring.js`). `RavixWeb.IconLabels` (`test/support`) reads
every template, and `test/ravix_web/icon_labels_test.exs` fails on an
icon-only control without both and proves the scan rejects and accepts.
`bun scripts/quality.mjs` checks pinned runtimes/actions and shared agent files.
`python3 scripts/coverage-self-test.py` runs disposable negative coverage fixtures.
The secret scanner has a `self-test` command; `.gitleaksignore` allows only exact,
reviewed historical fixture fingerprints. Never add a blanket path exemption.
Dependabot proposes weekly updates; scheduled audits detect new advisories even
without a code change. Update matching runtime pins together and run the guards.

Claude uses the same guide and skills through symlinks, so edits do not drift.
Fountain at `~/dev/binarybourbon/fountain` is a useful reference for its ownership
contract, SQL sandbox conventions, and coverage accounting. It is an umbrella
operator console; do not copy its product scope, deployment rules, or LiveView
exclusions into this single application.
