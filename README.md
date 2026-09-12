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

## Product surfaces

- `/` and `/inbox`: projects and tracks needing attention.
- `/home`: project selection; `/p/:project`: one project's tracks.
- `/p/:project/t/:track`: conversation, image attachments, queued prompts,
  presence, files, changes, GitHub checks/PRs, previews, command execution,
  and machine vitals.
- Project settings: harness/model, instructions, setup script, packages,
  write-only environment/vault secrets, preview defaults, and machine rebuild.
- Project and track sharing: GitHub usernames and revocable invite links.

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
| `FOUNTAIN_URL` | Fountain origin |
| `FOUNTAIN_API_KEY` | Server-owned Fountain account key |
| `GITHUB_APP_ID`, `GITHUB_APP_SLUG` | GitHub App identity |
| `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | GitHub App OAuth credentials |
| `GITHUB_PRIVATE_KEY` | GitHub App PEM key for installation-token requests |
| `GITHUB_API_URL`, `GITHUB_WEB_URL` | Optional overrides for development fixtures |
| `SPRITES_TOKEN`, `SPRITES_URL` | Sprites API credentials and optional origin override |
| `PREVIEW_DOMAIN` | Wildcard preview domain routed to the same service |
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

## Agent tooling (MCP)

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
```

This checks compilation with warnings treated as errors, unused lock entries,
formatting, Credo, Sobelow, Hex retirement audit, Dialyzer, ExUnit, browser-hook
DOM tests, and production release assembly. Run `bun install --frozen-lockfile`
once after cloning to install the development-only hook test dependencies.

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

`bun run test:browser` runs Chromium against a disposable production-mode app,
provider mocks, and a generated PostgreSQL database (ports 4103/8893/8894).
Install Chromium once with `bunx playwright install chromium`, and build assets
with `MIX_ENV=prod mix assets.deploy` first. Node is pinned alongside Elixir/OTP
and Bun in `.tool-versions`.

CI also enforces architecture rules, secret/dependency scans, agent-guide and
version consistency, generated lifecycle invariants, and negative fixtures for
the guards themselves. See [engineering quality](docs/engineering-quality.md)
for the required checks, local commands, and the boundaries each guard proves.
