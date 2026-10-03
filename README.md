# Ravix

A browser workspace for building software with coding agents, powered by
[Fountain](https://github.com/BinaryBourbon/fountain).

Sign in with GitHub, choose a repository, and give each piece of work a track:
its own git worktree, branch, and agent conversation on one persistent cloud
machine. Projects share their machine across tracks; you can close your laptop
while the agent works.

Ravix is an Elixir/Phoenix application with LiveView pages. The browser owns
local interaction—drafts, pasted images, terminal history, scrolling, resizing,
and themes—while contexts own data access and mutations.

## Development

Requirements: Elixir 1.19, Erlang/OTP 28, and PostgreSQL. CI and the Docker image
pin Elixir 1.19.5 / OTP 28.5 and use PostgreSQL 17.

The development database defaults to `ravix_dev` on localhost, with username
and password `postgres`; the test database is `ravix_test`. Adjust
`config/dev.exs` and `config/test.exs` for your local installation.

```sh
mix setup
mix phx.server
```

Open [localhost:4000](http://localhost:4000), which redirects to the sign-in
page: there is no marketing page, so the root is the workspace for somebody
signed in and `/login` for anybody else. Without external-service
configuration, that page renders; signing in and provisioning machines
require the services described below.

To develop against local fixtures, install Bun and run these in separate
terminals:

```sh
bun install
bun run mock
```

```sh
python3 scripts/dev-mock.py
```

The mock serves Fountain and GitHub on port 8793, and Sprites on port 8794.
Its sign-in page offers fake users and repositories. The development launcher
passes only those local endpoints and the generated `mock/dev-key.pem` to
Phoenix; no real GitHub account or cloud machine is used. For alternate ports,
set `PORT`, `MOCK_PORT`, and `MOCK_SPRITES_PORT`; set the mock's `RAVIX_URL` to
the corresponding Phoenix URL when launching `bun mock/server.ts` directly.

### Against the real dev GitHub App

`ravix-hq-dev` is a private GitHub App in the `ravix-hq` org for local
development (RAV-35). It has production's permissions, but its callback is
`http://localhost:4000/api/auth/callback` (and the `127.0.0.1` equivalent) and
its setup URL is `http://localhost:4000/api/auth/install`. Its credentials are in
the Infisical `ravix` project, **dev** environment, under the **`/app`** folder:
`GITHUB_APP_ID`, `GITHUB_APP_SLUG`, `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`,
`GITHUB_PRIVATE_KEY` and `PREVIEW_DOMAIN` (`preview.localhost`).

```sh
infisical run --projectId f382332b-11a1-4573-a986-78c1729dbc70 \
  --env=dev --path=/app -- mix phx.server
```

Then sign in at [localhost:4000](http://localhost:4000) with your GitHub
account. Install the app on the `ravix-hq` repositories you want to use from
<https://github.com/apps/ravix-hq-dev>. Because it is private, it can't be
installed on repositories outside the org.

- **Fountain and Sprites aren't included.** To open tracks or run previews, add
  `FOUNTAIN_URL`/`FOUNTAIN_API_KEY` for a Fountain team you own, and
  `SPRITES_TOKEN` for previews and the terminal.
- **The values are kept out of the environment's root on purpose.** `mix mcp.env`
  exports only the root, and `config/runtime.exs` reads `GITHUB_*` in every
  environment. A shell carrying them would change what `mix test` sees, and a
  multi-line PEM would break `.env`. Don't run the tests inside `infisical run
  --path=/app`.
- **Another port needs another callback URL.** Add it to the app's settings
  before signing in on a `PORT` other than 4000.

## Product surfaces

- `/` and `/inbox`: projects and tracks needing attention.
- `/home`: project selection; `/p/:project`: one project's tracks.
- `/search`: scoped full-text search across projects, tracks, pending prompts, and
  indexed human/assistant conversation text; see [search coverage](docs/workspace-search.md).
- `/schedules`: personal hourly, daily, or weekly project prompts (UTC), with
  editing, pause/resume, and links to the latest dispatched track.
- `/p/:project/t/:track`: conversation, image attachments, queued prompts,
  presence, files, changes, GitHub checks/PRs, previews, command execution,
  and machine vitals.
- Project settings: harness/model, instructions, setup script, packages,
  write-only environment/vault secrets, a project run script, and machine rebuild.
- [Conductor setup import](docs/conductor-setup-import.md): review shared repository
  setup and named cloud run scripts in Project settings → Machine, then apply only
  selected fields through the existing save flow. File-copy patterns are provisioning
  suggestions; scripts never run on discovery.
- Project and track sharing: GitHub usernames and revocable invite links.
- Desktop notifications, switched on from the rail: when a track finishes or
  fails while the tab is in the background, the browser says so.

Webhook-triggered project prompts are also managed from Schedules. See
[webhook routines](docs/webhook-routines.md) for credentials, JSON delivery,
idempotency, and dispatch outcomes.

Changes supports persistent human review discussions on files or old/new diff lines.
Checks lists the same discussions and links back to the file and original anchor.
Track readers can reply and resolve/reopen. Reviews never become transcript notes,
agent prompts, or GitHub comments. A revision fingerprints the file’s Git diff section, including blob indexes, rather
than a Git commit. Extra untracked files and reader/writer retrieval differences do
not invalidate tracked discussions. Changed files retain outdated discussions and
original line text; stale submissions require a refresh. Partial files and binaries
without blob identities remain unverifiable and cannot accept new anchors. Binary
and metadata-only changes accept file discussions only.

Schedules recheck the creator's project membership before opening each fresh
track and use the durable prompt queue. A cluster singleton polls every 30 seconds;
database claims prevent duplicate dispatches. Downtime coalesces missed occurrences
into one run. Claimed occurrences are not replayed after a crash or provider error:
check the dispatch status and project tracks before retrying manually. Pausing or
deleting a schedule stops future dispatches; already claimed runs may finish.

The terminal runs complete shell commands; it is not an interactive TTY.
Persistent application servers belong in Preview, whose process owns the
service, readiness checks, logs, and idle lease. Preview commands must honor
`$PORT`, bind to `127.0.0.1`, and refuse fallback to another port.

Native Android/iOS previews and the Mac runner are deferred under
[#11](https://github.com/ravix-hq/ravix/issues/11). The shared browser is deferred
under [#12](https://github.com/ravix-hq/ravix/issues/12).

## Configuration

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | Production PostgreSQL connection string |
| `PUBLIC_URL` | Public application origin, such as `https://app.ravix.sh` |
| `PORT` | HTTP port; defaults to 4000 |
| `RAVIX_SECRET` | Encrypts stored GitHub tokens and seeds cookie signing |
| `SECRET_KEY_BASE` | Optional explicit Phoenix cookie signing key |
| `FOUNTAIN_URL` | Fountain origin; production is the hosted `https://managoat.com`, on a dedicated account (see `render.yaml`) |
| `FOUNTAIN_API_KEY` | Server-owned Fountain account key. Full scope, and Fountain v0.17 or newer, for each person to connect their own Claude or Codex credential; a ChatGPT subscription also needs linking switched on for the account, and Fountain caps how many one account holds (ADR 0005) |
| `GITHUB_APP_ID`, `GITHUB_APP_SLUG` | GitHub App identity |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | GitHub App OAuth credentials |
| `GITHUB_PRIVATE_KEY` | GitHub App PEM key for installation-token requests |
| `GITHUB_API_URL`, `GITHUB_WEB_URL` | Optional overrides for development fixtures |
| `SPRITES_TOKEN`, `SPRITES_URL` | Sprites API credentials and optional origin override |
| `PREVIEW_DOMAIN` | Wildcard preview domain routed to the same service |
| `RAVIX_DEDICATED_OPEN_USER_IDS` | Comma-separated user IDs eligible for dedicated sandboxes, or `*` for everyone; empty or unset disables new dedicated opens |
| `RAVIX_WORKSPACE_ACCESS` | `true` lets workspace membership grant access (ADR 0009); anything else, or unset, keeps today's legacy project and track doors. One global switch with no cohort. Flip it only after every instance runs a release that reads it, incompatible queue workers have drained and the personal-workspace backfill has completed |
| `RAVIX_CREATOR_BILLING` | `true` makes every dedicated track opened from then on paid for by its creator, for every thread and harness whoever prompts it (ADR 0009 phase 6, [creator billing](docs/creator-billing.md)); anything else, or unset, keeps project-owner billing. Tracks opened before it was on stay owner-billed until they close, and turning it off later does not change a track already opened. Run `mix ravix.provider_secrets` (or its release equivalent) before flipping it |
| `RAVIX_ADMIN_GITHUB_IDS` | Comma-separated **GitHub numeric ids** allowed to run operator actions, currently `mix ravix.move_chatgpt_subscription`. By id rather than login, because a login is renameable and a freed one can be taken by somebody else. No wildcard; unset means nobody |
| `POOL_SIZE` | Production database pool size; defaults to 10 |
| `HONEYCOMB_API_KEY` | Sends OpenTelemetry traces to Honeycomb; unset means no exporter and no traces leave the process (ADR 0004) |
| `HONEYCOMB_SAMPLE_RATIO` | Fraction of traces to keep, `0.0`--`1.0`; defaults to `1.0` |
| `HONEYCOMB_ENDPOINT`, `OTEL_SERVICE_NAME` | Optional OTLP origin and service/dataset name overrides |
| `DEPLOY_ENV` | Names the deployment on every span; defaults to the Mix environment |
| `POSTHOG_API_KEY`, `POSTHOG_SECRET_KEY` | Product analytics and feature flags; nothing reads them yet (ADR 0004) |

The registered GitHub App callback remains `/api/auth/callback`; its setup URL
is `/api/auth/install`. Signing in starts at `/auth/github`. Secrets belong in
service configuration, not source control.

Every variable above that `render.yaml` marks `sync: false` is a secret, is
entered in the Render dashboard rather than the Blueprint, and is kept in the
`ravix` project of the Infisical instance under the same name. The two lists are
meant to match, so a new secret is added in both places. A secret that has a
name but no value yet is stored blank on purpose: every reader treats blank as
absent, so an unpopulated placeholder reaching the service is the same as the
variable not being set at all --- which is the only safe way for a placeholder
to travel.

## Remote AI clients

Ravix exposes authenticated MCP at `/mcp` and A2A 1.0 at `/a2a`. Connect Claude
Code with `claude mcp add --transport http ravix https://app.ravix.sh/mcp`, then
use `/mcp` to sign in and approve access. Tools configure projects, open tracks,
submit prompts and read results. Revoke clients from **Connected applications**
in the account dialog. See [remote agent tooling](docs/agent-tooling.md) for
scopes, idempotency, A2A task behavior and current limits.

## Developer tooling (MCP)

`.mcp.json` declares three MCP servers in the repository, so a checkout gets them
and there is no per-machine configuration to copy. Claude Code asks for approval
the first time it sees them --- in an interactive session only, so a fresh
checkout needs one `claude` run before they connect; `claude mcp
reset-project-choices` takes that approval back.

**Ravix's PostHog, Render and Honeycomb accounts are not the accounts the rest of
this machine uses**, and that is the whole reason these entries exist and are
shaped the way they are.

An MCP connection signs in as **one** account. The remote servers all default to
OAuth, which authenticates as whoever is logged in on the machine — so an OAuth
connection would land on the wrong PostHog organisation and the wrong Render
workspace, and pointing it at Ravix would take it away from every other project
here. Both providers answer this the same way: **a distinct server name and an
API key per account.** Hence `posthog-ravix` rather than `posthog`: a global
`posthog` and a project `posthog-ravix` coexist, one per account, and neither
shadows the other. Same-named entries in two scopes do not.

So each server takes an account-scoped key from the environment:

| Variable | Key to create |
| --- | --- |
| `RAVIX_POSTHOG_MCP_KEY` | PostHog personal API key on the **MCP Server** preset (<https://us.posthog.com/settings/user-api-keys?preset=mcp_server>, signed in as the account that owns Ravix's project). The preset scopes the key to one project, which is what keeps this connection from wandering the way an OAuth one does. |
| `RAVIX_RENDER_MCP_KEY` | Render API key (<https://dashboard.render.com/u/settings?add-api-key>) for the account owning the `ravix` service. Render keys cannot be scoped to one workspace: the key reaches every workspace its account belongs to. |
| `RAVIX_HONEYCOMB_MCP_KEY` | Honeycomb **Management API key**, as the `KEY_ID:SECRET` pair joined by a colon — the id is `hcamk_`-prefixed, so the whole value looks like `hcamk_...:...`. Created under *Account > Team Settings > API Keys*, by a team owner, and the secret half is shown **only** at creation. **Not** the ingest key `HONEYCOMB_API_KEY` that the application sends traces with, which cannot read anything. |

All three speak streamable HTTP natively, so none of them needs the `npx
mcp-remote` wrapper that Honeycomb's own documentation shows --- checked by
handshaking against each endpoint directly. One transport, no node subprocess.

Nothing secret goes in `.mcp.json` itself: it is committed, and the keys reach it
through `${VAR}` expansion, which Claude Code resolves in `command`, `args`,
`env`, `url` and `headers`. An unset variable is reported by `claude mcp list` as
a missing-environment-variable warning naming the variable, rather than as a
confusing 401 from inside a provider --- so an *absent* key is easier to diagnose
than a blank one, which is worth knowing if these are held as unpopulated
placeholders.

These are developer-tool credentials rather than anything the application reads,
so they live in the Infisical `ravix` project's **dev** environment and not in
`prod`, which mirrors what the deployed service runs on.

Two ways to get them into the environment, because **Claude Code expands
`${VAR}` from the process environment and does not read `.env` itself** --- a
`.env` sitting in the directory does nothing on its own:

```sh
mix mcp.env     # writes .env (gitignored, 0600) from Infisical's ravix/dev
direnv allow    # once; .envrc then loads .env on entering the directory
```

or with nothing on disk at all:

```sh
infisical run --projectId <ravix project id> --env=dev -- claude
```

`mix mcp.env` refuses to write unless git already ignores `.env`, since writing
credentials to a committable path is the one way it could do harm. It also says
which values are still blank placeholders, because a blank is worse than a
missing one here: Claude Code names a missing variable and a blank one becomes a
401 from inside the provider. `.env.example` lists the three names with no
values.

`render-ravix` is worth one deliberate thought before enabling: Render's MCP can
change a service's environment variables and trigger deploys, so it is write
access to production, not a read-only window onto it.

## Database and cutover

Elixir uses the dedicated PostgreSQL schema **`ravix`**, including its migration
history. `mix ecto.migrate` and the release's `bin/migrate` create that schema
before applying migrations. Context queries use it by default.

The old Bun application's `public` tables are preserved and are not imported.
This is a fresh application-data cutover, as chosen in the rewrite decision;
users sign in again and create their projects in the Elixir application. There
is no legacy data to import. Do not drop the public tables as part of
deployment.

```sh
mix ecto.migrate
mix ecto.rollback
```

For a release:

```sh
/app/bin/migrate
/app/bin/server
```

`render.yaml` keeps the existing Render service and database, runs migrations
before swapping the release, and deploys main only after CI passes. Wildcard
preview DNS/TLS must route `*.PREVIEW_DOMAIN` to this same HTTP service. The
preview gateway isolates application content on those separate origins and
requires a session-bound ticket for access.

## Validation

```sh
mix precommit
mix precommit.release   # after a change to configuration, assets, or the release
```

`mix precommit` checks compilation with warnings treated as errors, unused lock
entries, formatting, Credo, Sobelow, Hex retirement audit, Dialyzer, ExUnit
(including the `:distributed` cluster tests a plain `mix test` skips), and the
browser-hook DOM tests. `mix precommit.release` is the production build on its
own: assets and release assembly, the way CI's release job does them. Run
`bun install --frozen-lockfile` once after cloning to install the
development-only hook test dependencies.

Coverage counts production source only, excluding test fixtures. The total floor
is 90%; separate floors require server 92%, web 90%, workspace LiveView 92%, and
track LiveView 92%. `mix test --cover` writes the native HTML report and
`cover/quality.json`. Each JavaScript hook requires 90% line and function coverage
under `bun test`, with LCOV in `cover/hooks/`. CI retains both reports as artifacts.
The floors live in `coverage.exs` and `bunfig.toml`; raise them as coverage grows.

[AGENTS.md](AGENTS.md) is the contributor/agent guide (also read through
`CLAUDE.md`). Repository skills cover scoped Elixir changes and coverage-driven
testing. See [engineering quality](docs/engineering-quality.md) for the measured
baseline, design choices, and the limits of each test layer.

CI also migrates and boots a production release. To exercise the actual
container locally with disposable PostgreSQL 17 and verify legacy-table
preservation:

```sh
docker build -t ravix-elixir-check .
scripts/release-smoke.sh ravix-elixir-check
```

The script cleans up the containers and network it creates. It checks `/healthz`,
the sign-in page and assets, migration idempotence, and that a pre-existing
`public.users` table survives unchanged.

The narrow Dialyzer filters in `.dialyzer_ignore.exs` document an upstream
`mint_web_socket` 1.0.5 opaque-type mismatch. The corresponding transport paths
are covered by real socket tests. Sobelow exclusions are beside the specific
safe upload, escaped markdown, and preview-origin response functions.

## Code map

Start with the [architecture guide](docs/architecture.md) for diagrams of the
system, ownership boundaries, prompt delivery, previews, and cluster recovery.

| Area | Location |
| --- | --- |
| Data, access, service clients, supervised processes | `lib/ravix/` |
| Router, OAuth/preview controllers, LiveViews, shared components | `lib/ravix_web/` |
| Browser hooks and shared stylesheet | `assets/` |
| Ecto migrations | `priv/repo/migrations/` |
| ExUnit tests and HTTP/socket fixtures | `test/` |
| Local TypeScript service fixtures | `mock/`, with the four values it copies from Elixir in `shared/contract.ts` |
| Architecture decisions | `decisions/` |

Bun is a development dependency only. It runs the `mock/` service fixtures, the
`assets/test/` hook tests, and Playwright; nothing it builds is served, because
Phoenix compiles `assets/` through `mix assets.deploy`. Older feature briefs in
`docs/` describe the pre-migration system and are historical references; the
code they describe lives in Git history.

### Additional quality guards

Browser smoke tests and tests for exact UI copy, literal strings, component
markup/classes, labels/tooltips, themes, layout, or other visual cosmetics are
deprecated and disabled by default. Prefer focused ExUnit and Happy DOM hook
tests for behavior; use the `*:deprecated` browser scripts only when explicitly
needed.

CI also enforces architecture rules, secret/dependency scans, agent-guide and
version consistency, generated lifecycle invariants, and negative fixtures for
the guards themselves. See [engineering quality](docs/engineering-quality.md)
for the required checks, local commands, and the boundaries each guard proves.

### User-facing changelog

When a change is visible to people using Ravix, add a reviewed entry to `Ravix.Changelog` in `lib/ravix/changelog.ex`. Entries use a plain-language title and body, a date, and one of `new`, `improved`, or `fixed`; keep them concise and include an action when it helps someone try the change.

### Thread runtimes

Each new thread records its runtime and model. The new-track form chooses the
first thread. New threads use the starter's preferred runtime/model if the
project owner's credentials and runtime gates allow it, then the track's last
runtime, then the project default. The dialog labels the source. Set **Default
agent for new threads** in Your account; explicit dialog or composer model picks
also save that person's preference. Choosing the project model in the composer
clears the saved preference, restoring derivation from connected credentials.
MCP runtime/model arguments never change a person's preference. Existing threads retain their runtime.

The model menu also offers the runtime's **effort** and **Fast** where the
conversation's runtime advertises them (Fountain ADR 0062,
`Ravix.SessionConfig`): the `thought_level` option with the adapter's own
values and names, and a Fast toggle from `model_config`. Claude calls them
`effort` and `fast`, Codex `reasoning_effort` and `fast-mode`, and which
models offer which values is the adapter's to say. They appear once the
conversation's first turn has reported its options, and are hidden on a
Fountain without them. The thread keeps its choice (`threads.session_config`)
and sends it as every prompt's `session_config`, because Fountain applies a
prompt's options to that turn only. Each turn's footer names what it ran with
and any option the model skipped; a refused value fails the turn before the
prompt, with the runtime's message and a way to change it. The choice is also
remembered per runtime as the person's default for new threads.

Until explicitly chosen, the preference uses the most recently connected held
credential (ChatGPT link, API key, or Claude token) and that runtime's default
model: the catalog's known default (`anthropic/claude-opus-5` or
`openai/gpt-6-astra`), otherwise an Opus model, otherwise the first listed model.
Successful connections record timestamps locally. Pre-existing
connections lack historical timestamps: they use the account's recorded agent,
then the connected credential order, until reconnected or explicitly chosen.
MCP `create_track` shares this resolver when runtime is omitted; `send_prompt`
continues its existing thread without changing its runtime/model. Nullable legacy
threads retain the project's runtime/model.
Threads share a checkout and may work concurrently; the tabs identify those
mid-turn, and users coordinate conflicting edits.

Pickers use the **project owner's** connected runtimes. Other-runtime threads
(on shared machines too) require the initiating user to be in
`RAVIX_DEDICATED_OPEN_USER_IDS`, the same cohort as dedicated opens. The server
checks this gate independently. Keep that cohort empty until the owner completes
`scripts/fountain-sandbox-check.py` against real Fountain. Home-runtime threads
and model choices do not require the cohort flag.

A project reuses one agent per runtime. The first shared-machine launch pins its
home runtime atomically; a competing other-runtime launch waits for that machine
instead of provisioning another disk. `project_runtime_agents` reserves an
additional runtime before its create request. An interrupted or uncertain create
leaves `agent_id` null and refuses further allocation; an operator must reconcile
the provider agent by its project metadata/runtime and bind its ID, or prove no
agent was created before removing the reservation. Do not clear a reservation
merely because a request timed out. Shared rebuild/deletion fences new agent
allocations and retires both runtime agents; unresolved reservations block that
cleanup. Rebuilding successfully clears the retirement fence.

Dedicated opens are disabled by default. Do not add anyone to
`RAVIX_DEDICATED_OPEN_USER_IDS` until **managoat/fountain#2527 is deployed** and
the owner has passed `scripts/fountain-sandbox-check.py` against real Fountain.
The lifecycle is tested against the mock only. Each flagged open persists intent,
copies the project's secrets server-side, refreshes repository access on that
copy, and provisions one persistent machine with an ordinary clone. Scratch
projects skip cloning. Setup holds saved prompts until the working directory is
verified. The first thread selects the project's home-runtime agent for this disk.

Secret copies are snapshots. Editing project secrets pauses dedicated tracks and
shows **Secrets changed — rebuild to apply**; an explicitly confirmed rebuild
replaces the machine and its copy. An unconfirmed source-secret write also holds
new copies and overlapping saves. An operator must confirm an interrupted write's
outcome before clearing its persisted pending generation; no database connection
is held while writing to Fountain.
Closing is durable and remains visible while cleanup retries. It ends every
thread, deletes the machine, confirms its absence, and deletes the copied secrets.
Shared open/close is unchanged by default. Only the separately enabled
`RAVIX_RETIRE_SHARED_MACHINES=true` retires the old machine after the final shared
track closes, retaining project secrets and runtime agents. Retirement gives up
after five attempts, keeps a failed operation for inspection and releases the
shared-open fence.

Operation leases and generations fence workers across nodes. Lost allocation
responses are reconciled by the operation's copy name and full machine identity.
An empty provider listing after an uncertain mutation is not proof that it did
nothing: the intent and cleanup obligation remain pending rather than allocating
again. An operator must resolve persistent ambiguity at the provider; do not clear
operation records or retry with a different identity to bypass it.

### Project run scripts

Project settings → Run script stores the directory, startup command, optional
stop command, and optional HTTP readiness path. Existing preview defaults are
read as run scripts in place; there is still one project configuration. Each
track inherits it and can save its own override in the Run panel.

Run / Restart / Stop use the existing managed Sprites service. Without an HTTP
readiness path, a process reports running and output, with no preview URL; it
continues until stopped or its track is retired. With a readiness path, the app
must honor `$PORT` and fail on a port collision. Readiness enables the existing
private preview and its viewing/idle lease behavior.

A stop command runs in the applied service directory with its assigned `$PORT`
and `HOST=127.0.0.1`, with a 15-second limit. Stop then signals the managed
service process group, including when the custom command fails. Restart and
configuration changes also stop the previous service using its applied stop
command. Shared tracks keep their separate port allocations; dedicated tracks
run on their own machines.

The track agent helper supports `run` (an alias for `start`), `restart`, `stop`,
`status`, and `logs`. The MCP catalog exposes preview/run configuration, start, restart, stop, status,
and bounded logs; see [agent tooling](docs/agent-tooling.md#preview-and-run-tools).

Plain run scripts are observed after startup, not automatically relaunched.
A successful exit becomes stopped; a non-zero exit, provider failure, or
provider restart becomes failed. Run or Restart explicitly starts another run.
Custom stop-command failures are warnings in output and do not prevent managed
service cleanup or Restart. Plain scripts keep the track's machine awake while
running; the Run panel shows this cost before starting them.

During a mixed-version deployment, an old instance hosting the global preview
server ignores `stop_command`, times out plain scripts as failed, and applies
its preview idle shutdown. These limitations end once every instance runs the
new release; wait for that rollout before relying on plain scripts or custom
shutdown commands.
