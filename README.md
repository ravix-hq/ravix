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

The registered GitHub App callback remains `/api/auth/callback`; its setup URL
is `/api/auth/install`. Signing in starts at `/auth/github`. Secrets belong in
service configuration, not source control.

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
