# Ravix in Elixir

An exploration, written 2026-09-09 against the Fountain repository as it
stood that day (OTP 28.3, Elixir 1.19.2, Phoenix 1.8, LiveView 1.2) and
this repository at the merge of #10. Nothing described here is built.

## The short answer

A rewrite is feasible, and the timing is unusually good. There is no
production data and no user to migrate, the Render service and Postgres
stood up this week carry over unchanged, and Fountain already ships the two
libraries a Ravix server leans on hardest: the Elixir SDK covers every one of
the twenty-five Fountain calls Ravix makes, and the Sprites adapter in
`managoat_sandbox` covers most of the Sprites ones.

It is also a real project. About 9,600 lines of server TypeScript and 3,300
of tests become roughly 6,000 to 8,000 lines of Elixir, and the two
WebSocket relays (track previews, native video) are hand-built on Mint where
Bun handed us `node:http` and `ws`.

The rewrite takes the UI with it: the React SPA becomes LiveViews, so the
`/api` surface the two halves negotiate over today is retired rather than
preserved. That roughly doubles the port (the SPA is another 10,400 lines)
and removes a whole layer in exchange: no API contract, no SSE hub, no
client-side transcript parser, one language everywhere.

Three things do not come across: the native preview experiment (Android
and iOS through a Mac runner), the shared browser, and the `runner/`
daemon that serves both. They are a fifth of the server and their own
wire protocols, they were demonstrated but never had a second user, and
they carry the only client-side video code in the product. They return as
features after the rewrite, tracked as issues #11 and #12, and the port is
scoped without them. The recommendation: do it now, while there is nothing
to migrate. If the goal is only the discipline, most of it transfers to the
TypeScript codebase in days without a rewrite. Both are laid out below.

## Sizes

| Area | Lines | Files | Fate |
| --- | ---: | ---: | --- |
| `server/` production, ported | 7,690 | 30 | rewritten |
| `server/` production, cut | 1,900 | 10 | native experiment, runner coordination and store, forward gateway, shared browser and its store; return under #11 and #12 |
| `server/` tests | 3,362 | 23 | rewritten as ExUnit, less the five files for the cut modules |
| `src/components/` React, ported | 7,407 | 27 | rewritten as LiveViews, LiveComponents and HEEx, with a handful of JS hooks |
| `src/components/` React, cut | 407 | 2 | `NativePreview.tsx` and `SharedBrowser.tsx` |
| `src/lib/` client logic | 1,882 | 10 | markdown, tool rendering and the ACP flattening move server side; theme and images become hooks |
| `src/` tests | 1,301 | 19 | rewritten as `Phoenix.LiveViewTest` |
| `shared/` | 1,751 | 14 | the API types retire with the API; `spec.ts` and `ids.ts` (the slug and channel contract) port; `native-preview.ts`, `runners.ts` and `browser.ts` go with their features |
| `runner/` macOS daemon | 3,825 | 36 | cut; the daemon returns with #11 |
| `mock/` fake Fountain, GitHub, Sprites | 1,223 | 2 | usable from Elixir dev unchanged; it speaks HTTP |
| `packages/fountain-app` ACP parser | 710 | 8 | replaced by `managoat_acp` on the server |

The current suite is 410 tests across 60 files. About 21,000 lines of
TypeScript are in scope for the port; the Elixir that replaces them is a
guess at 10,000 to 13,000, plus a little JavaScript in hooks.

## What Fountain established, and what transfers

| Practice | In Fountain | For Ravix |
| --- | --- | --- |
| Tenant scoping | every user-facing query takes `user_id`; unscoped functions carry the `_unsafe_` prefix and sit adjacent to the scoped fetch that established ownership | `trackAccess`, `projectAccess` and `projectOf` are already this shape; they become the context API and the prefix rule comes with them |
| Audit in the context | a mutation records its own event; a guardrail test fails until it does | Ravix has no audit trail today; optional, but the guardrail pattern is cheap once contexts exist |
| Tests | `DataCase` on the SQL sandbox, `async: true`, a factory through real changesets, Mimic, no fire-and-forget `Task.async` | replaces the per-fixture schema reset on PGlite; the SQL sandbox is what that reset was imitating |
| `mix precommit` | compile with warnings as errors, unused deps, format, `credo --strict`, dialyzer, sobelow, a prod release assemble, tests | copy the alias verbatim |
| CI | the suite in partitions, an 85% coverage gate, hex audit, release boot check; a red-then-green run is investigated and filed, not rerun | copy `ci.yml` and `coverage.exs`; one partition is enough at this size |
| Decisions | ADRs as an OKF bundle, validated in CI, indexed by script; unbuilt behaviour is never described as built | copy the template and the workflow; the first ADR is this rewrite |
| Docs guardrails | the manual is compiled in, every page in the nav, links and anchors checked | not applicable; Ravix has a README, not a manual |
| Extensions and libraries | an umbrella so first-party extensions and the `managoat_*` libraries have a boundary | not needed; Ravix is one application, one OTP app |

## What already exists to reuse

**`fountain_sdk` 0.1.0** (hex). Conversations with `channel_id`, `fresh`
and `environment_id` at creation, prompts, interrupt, terminate, turns,
events over SSE with reconnect, history with blocks; sandboxes with files,
file and diff; catalog and me; agents, environments and vaults with
write-only secrets. That is the whole of `server/fountain.ts` and the SSE
reader in `packages/fountain-app`.

**`managoat_sandbox`** (hex, Apache-2.0). The Sprites adapter has `exec`,
`spawn`, `attach`, `write_file`, checkpoints, network policy and
`public_url`, behind a behaviour with a Fake and a conformance case for
tests. Ravix also uses three things it does not have: services (define,
start, stop, delete, logs), the task activity lease that keeps a preview's
machine awake, and the raw `/proxy` WebSocket tunnel the preview gateway
rides. Those are about 150 lines in `server/sprites.ts` and
`server/sprites-tunnel.ts`; they belong upstream as adapter additions, or
live in Ravix until they do.

**`managoat_acp`**. ACP to blocks, on the server, which is where the
transcript is rendered now. It replaces `packages/fountain-app` and
`src/lib/tools.ts` outright. `Managoat.Docs.Markdown` is the sanitising
markdown pipeline Fountain uses for agent output and can replace
`src/lib/md.ts`.

**LiveView in Fountain.** Thirty LiveView modules, about 9,900 lines, and
`FountainWeb.Live.Hooks` with the `on_mount` guards (`require_authenticated_user`
and friends) to copy. One thing to know before leaning on that experience:
Fountain's LiveViews are console pages, forms and tables, and its `assets/`
holds CSS only. There is not a single JavaScript hook in it. Ravix has a
terminal, a composer that takes pasted images, a transcript that follows
its own tail, resizable panels and a theme picker. Those need client code
however the page is served, so the LiveView Ravix sets the hook precedent
for both codebases. With the two video viewers cut, none of the hooks is a
client program; each is a few dozen lines around one element.

**Not there.** Fountain signs people in with `ueberauth_github`, an OAuth
app, not a GitHub App. The App JWT, installation tokens with their
one-hour cache, and the installation-scoped repository listing that
`server/github.ts` does are new code: JOSE for RS256, Req for the calls,
about 300 lines. Fountain also has no WebSocket client or reverse-proxy
dependency; the preview gateway brings `mint_web_socket` with it.

**Copy as is.** The Dockerfile (a Phoenix release on a slim Debian base,
the shape Render's Docker runtime wants), `ci.yml`, the `precommit` alias,
`test/support` (`DataCase`, `ConnCase`, the factory), the LiveView hooks
module, the ADR template and its validation workflow.

## Module map

Effort is relative to the rest of this table, not a calendar.

| Today | Lines | In Elixir | Effort | Note |
| --- | ---: | --- | --- | --- |
| `db.ts` and the four stores | 1,600 | Ecto schemas, migrations and contexts: Projects, Tracks, People, PromptQueue, Previews, Browsers, NativeRunners | medium | Migrations replace `CREATE TABLE IF NOT EXISTS` at boot. The serialised-transaction adapter written this week disappears; the SQL sandbox and `Repo.transaction` are the native forms |
| `context.ts`, `auth.ts`, `oauth.ts`, `github.ts` | 1,000 | Accounts and GitHub contexts, a session plug, JOSE | medium | The `_unsafe_` convention lands here |
| `app.ts`, `http.ts` | 330 | the router; a handful of controllers for what is not a page (the OAuth callback, `/healthz`, the preview gateway's control routes, the runner socket) | low | The JSON API retires with the SPA |
| `hub.ts`, `stream-access.ts`, `presence.ts` | 400 | `Phoenix.PubSub`; each LiveView subscribes to its project and re-checks access as it handles a message | low | The SSE stream and its access filter disappear; presence is `Phoenix.Presence` |
| `projects.ts`, `tracks.ts`, `repos.ts`, `people.ts` | 2,100 | contexts over the SDK | medium | The product logic; the bulk of the port |
| `prompt-queue.ts` | 183 | Oban jobs unique per track, or one GenServer per track | low | Durable retries come free either way |
| `previews.ts`, `preview-store.ts` | 470 | one process per preview under a DynamicSupervisor and Registry | medium | The serial operations, leases and reconcile ticks map one to one onto a GenServer |
| `preview-gateway.ts`, `preview-front.ts`, `sprites-tunnel.ts` | 480 | a host-scoped Plug (the router's `host:` prefix match) doing a streaming reverse proxy, and a WebSock handler relaying to the sprite over `Mint.WebSocket` | high | The one place Bun was genuinely easier. The single-port front written this week stops being needed: the router matches on Host |
| `sprites.ts`, `terminal.ts`, `vitals.ts` | 590 | `managoat_sandbox` plus the three additions; vitals as a sampling GenServer | low to medium | |
| `browsers.ts`, `agent-browser.ts`, `browser-store.ts` | 330 | cut | | Returns under #12 |
| `native-experiment.ts`, `runner-coordinator.ts`, `runner-store.ts`, `native-forward-*.ts` | 1,530 | cut | | Returns under #11, with the `runner/` daemon |
| `machine-cache.ts` | 113 | ETS with a TTL | low | |
| `config.ts`, `index.ts`, `sql.ts`, `crypto.ts` | 520 | `runtime.exs`, the application supervisor, AES-GCM through `:crypto` | low | Same environment variable names, so `render.yaml` loses three lines and otherwise does not change |

And the UI, by surface:

| Today | Lines | In Elixir | Effort | Note |
| --- | ---: | --- | --- | --- |
| `App.tsx`, `Yard.tsx`, `Dock.tsx`, `Inspector.tsx`, `Home.tsx`, `Landing.tsx` | 1,390 | one `live_session`; `/p/:project/t/:track` stays the address; the shell is one LiveView, the rail and dock are components | medium | The URL-is-the-selection rule survives: `handle_params` is exactly that |
| `Transcript.tsx`, `lib/tools.ts`, `lib/transcript.ts`, `lib/md.ts` | 1,190 | a LiveView stream of blocks from `managoat_acp`, markdown through `Managoat.Docs.Markdown`; a hook for follow-the-tail and copy-code | high | The largest surface and the one that streams; `phx-update="stream"` with temporary assigns is the discipline to get right |
| `Composer.tsx`, `lib/images.ts` | 375 | a LiveComponent with a hook for paste, drop and shortcuts; images upload through `allow_upload` | medium | |
| `Terminal.tsx`, `Run.tsx`, `Vitals.tsx` | 540 | LiveViews over the Sprites context; a hook owns keystrokes and scrollback locally and sends commands | medium | Keystrokes never round-trip; a submitted command does |
| `Files.tsx`, `Changes.tsx`, `Checks.tsx` | 909 | LiveViews; the diff and the tree render on the server | medium | |
| `People.tsx`, `ProjectSettings.tsx`, `NewProject.tsx`, `CreateFrom.tsx`, `Setup.tsx`, `CloseTrack.tsx`, `TrackName.tsx`, `Search.tsx`, `Dialog.tsx` | 2,590 | forms and dialogs: LiveComponents with changesets | medium | Fountain's home ground; its console is nothing but this |
| `NativePreview.tsx`, `SharedBrowser.tsx` | 407 | cut | | The two client-program viewers go with their features |
| `PanelResizeHandle.tsx`, `ThemePicker.tsx`, `lib/theme.ts`, `lib/presence.ts`, `lib/icons.tsx` | 660 | hooks for drag and theme; `Phoenix.Presence`; icons as function components | low | |

## What gets better, what gets harder

Better. The concurrency that was hand-rolled this week to survive the move
to Postgres (serialised transactions through `AsyncLocalStorage`, per-socket
promise chains, in-flight flags, a liveness cache) is what supervision trees
and mailboxes are for. PubSub replaces the hub, and with LiveView the SSE
stream, the access filter on it, the JSON API and the client parser all go
too: a LiveView process holds the transcript and is told when it changes.
The SQL sandbox replaces the schema reset. A release with telemetry replaces
a bundle. Migrations replace boot-time DDL. Tests are one suite,
`LiveViewTest` driving the real page against the real contexts. One
language with Fountain means the SDK, the sandbox adapters, the ACP blocks
and the markdown pipeline are maintained upstream, and the tenancy
vocabulary is shared.

Harder. WebSocket relaying and streaming reverse proxying are lower level in
Elixir than in Bun. Five surfaces need small hooks regardless, and Fountain
has no hook precedent to copy. The transcript is the one LiveView that
streams hard, and long transcripts need the stream and temporary-assign
discipline from the first commit. The SPA's interaction tests stop being an
acceptance test the day the SPA goes, so parity is checked by hand against a
list. And the port is months of work rather than weeks, with the transcript
and the preview gateway the parts most likely to run over.

## Three ways to go

**Rewrite server and UI together.** Server contexts and their LiveViews
land surface by surface; the JSON API is never rebuilt. The Render service
swaps its Dockerfile, keeps its Postgres, and Ecto migrations build a fresh
schema because there is nothing to keep. This is the recommendation if the
stack is the goal, and the window for it is now: it closes at the first
real user.

**Strangler, Phoenix in front of Bun.** A Phoenix service proxies unported
routes to the Bun server as a Render private service, and pages move one at
a time with the SPA shrinking around them. Two UIs in one product for the
whole transition, and not worth it with zero users and no data to protect.

**Port the discipline, keep TypeScript.** typescript-eslint at strict, a
`precommit` script mirroring `mix precommit`, a coverage gate in CI, the ADR
bundle with `okf validate`, the flake rules, the `_unsafe_` naming for the
few unscoped queries. Days of work, most of the discipline, none of the
runtime.

## The sequence, if it is the rewrite

Each step lands its contexts and its pages together, so there is a working
app at every step and never two UIs.

1. **Skeleton.** A single Phoenix application, not an umbrella. Fountain's
   `precommit`, `ci.yml`, `test/support`, LiveView hooks, ADR bundle and
   Dockerfile copied in. `/healthz`, the shell LiveView with the landing
   page, `render.yaml` pointing at the new Dockerfile. The first ADR: Ravix
   in Elixir and LiveView, the API retired.
2. **Data and identity.** Ecto schemas and migrations for every table,
   contexts under the tenancy rule, GitHub App sign-in, sessions; the
   People, settings and invite pages.
3. **Machines.** Projects and tracks over `fountain_sdk`, the machine cache,
   PubSub, the prompt queue; the yard, the track view, the transcript on
   `managoat_acp`, the composer.
4. **Sprites.** Exec, terminal, run and vitals over `managoat_sandbox`; the
   files, changes and checks pages; the services, activity and proxy
   additions contributed upstream.
5. **Previews.** The preview processes, the host-scoped gateway with the
   WebSocket relay, the preview page. The wildcard domain and certificate
   already exist on Render.
6. **Cutover.** The Bun server, the SPA, `runner/` and the cut modules
   leave the repository in the same change that makes the Elixir release
   the deployed one. Issues #11 and #12 hold what comes back.

## Decisions this needs

- Same repository with `server/` replaced, or a new one. Same is simpler:
  the SPA, `shared/`, the mock and the runner all stay where they are.
- Where client code is allowed. Fountain's rule that interactive apps are
  SPAs is about apps on Fountain's `/api` from other origins; Ravix owns its
  server, so LiveView is inside the rule. What still needs deciding is the
  hook policy: keystrokes, drag, paste and theme stay in the browser, and
  everything else renders on the server. Write it down, because the first
  "just a little JS" is how a second SPA grows.
- The three Sprites additions: upstream into `managoat_sandbox`
  (Apache-2.0, its own repository) or local to Ravix. Upstream, so the
  Fake and the conformance case cover them.
- Which guardrails come across: tenancy, coverage and ADRs, yes; the audit
  trail is a product question; the docs gates do not apply.
- When the cut features return, and in what shape. The shared browser is
  a context, a process and a hook that is a real client program; the
  native experiment is that plus a Mac daemon and a binary protocol. Both
  get their own ADR when their turn comes, not now.
