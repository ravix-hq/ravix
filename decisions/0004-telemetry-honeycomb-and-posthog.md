---
type: ADR
title: "Telemetry: OpenTelemetry traces to Honeycomb, product analytics and feature flags in PostHog"
description: "Performance is answered with OpenTelemetry traces exported to Honeycomb over OTLP/HTTP, through one `Ravix.Trace` door that sanitises attributes, suppresses recurring background work, and carries context across this application's many process hops. Product analytics and feature flags go to PostHog server-side only, with no browser SDK, no autocapture and no session replay -- neither of those two is built yet."
tags: [architecture, observability, privacy, operations]
status: stable
adr: "0004"
adr_status: "Accepted"
date: 2026-09-11
generated: { by: claude-opus/5, at: 2026-09-12T00:40:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-09-12T00:35:00-04:00 }
stale_after: 2026-12-11
---

# 0004 — Telemetry: Honeycomb for performance, PostHog for product

**Status:** Accepted. Built and not built, explicitly, because two thirds of
this decision is a plan:

  * **Built:** the OpenTelemetry pipeline and its exporter, HTTP/LiveView/Ecto
    instrumentation, `Ravix.Trace` with its attribute sanitiser, its
    cross-process context carrying and its suppression of the prompt-queue
    sweep, and spans at the Fountain, Sprites, GitHub, track-read, preview-
    operation and prompt-delivery boundaries.
  * **Built since:** PostHog capture. The SDK, its configuration, `Ravix.Analytics`
    and eight events at context boundaries. `Ravix.Redact` is now shared between
    the two halves, because a span attribute and an event property are the same
    hazard and had better answer to the same rule.
  * **Not built:** feature flags. No flag is read anywhere, and
    `POSTHOG_SECRET_KEY` -- which exists only so that reading one is not a
    network call per mount -- is configured and unused. The `Ravix.Flags`-shaped
    boundary described below does not exist yet, and this caveat and
    `stale_after` come off in the PR that builds it.

`verified` therefore covers both built halves, and `stale_after` stays until
flags are. What it means, since "verified" in an ADR is usually a claim about
code, and since this one rests on somebody looking at two screens:

  * **Traces reach Honeycomb from the deployed release** (2026-09-11,
    https://app.ravix.sh, dataset `ravix` in team `ravix`, environment `prod`),
    confirmed in the Honeycomb UI by the operator. That is the one thing no test
    here could establish, and it exercises the whole path at once: OTLP over
    HTTP/protobuf, the `x-honeycomb-team` header, the resource attributes, and
    the release actually reading `HONEYCOMB_API_KEY` at boot rather than at
    compile time.
  * **Events reach PostHog from the deployed release** (2026-09-12, release
    `a68bf37`), confirmed by the operator seeing `signed in` arrive in Ravix's
    PostHog project. The same class of proof as the traces above and for the same
    reason: the tests read events back through the SDK's `test_mode`, which shows
    that the events and their properties are right and cannot show that PostHog
    accepts them.
  * Both PostHog keys were checked before the deploy, and checked *together*:
    `/api/feature_flag/local_evaluation` accepted the project key and the `phs_`
    secret as a pair, which is the only way to know they belong to the same
    project. A mismatched pair is accepted individually and then returns no flags,
    silently, which is a failure that would have surfaced only in the flags PR.
  * The ingest key was checked against Honeycomb's `/1/auth` before the deploy
    and answered `type: ingest`, team `ravix`, environment `prod`,
    `createDatasets: true`, on the **US** instance — which is why no
    `HONEYCOMB_ENDPOINT` override is set. The EU endpoint rejected the same key,
    so a future migration between instances will present as a valid key that
    silently exports nowhere.
  * **Not verified in production:** the parent/child structure of a trace. It is
    proven by test instead — `RavixWeb.TrackLiveTraceTest` asserts that a click
    on the track page and the read it starts share a trace id with the read as
    the child, across a process boundary — but nobody has read a real waterfall
    against that expectation. The tests read spans back through an in-memory
    exporter (`Ravix.TraceCase`), so what they cannot show is how Honeycomb
    renders them.
  * **Not verified at all:** sampling below 1.0. `HONEYCOMB_SAMPLE_RATIO` has
    only ever been exercised at its default and by a unit test of its parsing.
  * **Not verified either:** seven of the eight events. Only `signed in` has been
    seen arriving; the rest are proven by test and by sharing one door with it.
    The properties most worth a second look when somebody does check are the two
    that were argued about --- that `ravix.repo` carries what it should, and that
    no prompt text appears anywhere near `prompt sent`.

## Context

Ravix had no telemetry of its own. `RavixWeb.Telemetry` was the generated
Phoenix file with its reporters still commented out, and the only
`:telemetry.attach/4` anywhere in the tree was a test helper that counts
queries. So there was nothing to turn on: the events did not exist.

The gap was becoming expensive. The five commits before this one (#126--#130)
were all performance work on the track page — drawing what has answered instead
of the slowest read, handing the page from track to track instead of rebuilding
it, doing per-event work once a window — and every one of them was reasoned
about from the code rather than measured. `Ravix.Vitals` answers "is it me or is
it the box" for a *user's* machine, deliberately, and says so; it says nothing
about this server.

Four things about this application make instrumenting it more than adding a
dependency:

  * **Almost nothing happens in the process that decided to do it.** Both pages
    read through `start_async/3` (seventeen call sites) because a LiveView that
    reads inline stops drawing and stops answering clicks. The preview server
    runs its operations under `Task.Supervisor.async_nolink/2`; prompt delivery
    runs under `async_stream_nolink`. OpenTelemetry's current span lives in the
    process dictionary and crosses none of those.

  * **Two things are long-lived on purpose.** `Ravix.Tracks.Follower` holds a
    Fountain event stream open for as long as anybody anywhere is looking at a
    transcript; `Ravix.Sprites.Tunnel` holds a websocket. A span around either
    never ends, and an unended span is not a slow row on a waterfall — it is a
    trace the exporter holds until the process dies.

  * **Recurring work runs on every instance.** ADR 0003 keeps the prompt-queue
    sweep on all of them deliberately, every two seconds, because it is
    idempotent and merely cheaper once. Its two queries, traced naively, are two
    parentless root traces per sweep: tens of thousands of empty traces a day
    per instance, at a per-event price.

  * **Credentials are everywhere in this process and nowhere in the browser.**
    `Ravix.Config` exists because sign-in is GitHub while every machine runs on
    *this server's* Fountain key, so four secrets live in this process; its
    answer is a redacting `Inspect` on every credential-bearing struct. A span
    attribute does not go through `Inspect`.

On the product side there is no analytics of any kind, no way to answer whether
a feature is used, and no way to put one behind a flag — which means every
change ships to everybody at once.

## Decision

**Performance is traces, exported to Honeycomb.** `opentelemetry` with the OTLP
exporter over **HTTP/protobuf** to `api.honeycomb.io`, configured in
`config/runtime.exs` only when `HONEYCOMB_API_KEY` is set; without it the
`:none` exporter and `:always_off` sampler from `config/config.exs` stand and
tracing is inert, which is a property with enough to it that it has a section of
its own below. Honeycomb separates environments by the key, and files traces under the
dataset named by `service.name`, so the same configuration serves staging and
production. `service.instance.id` carries the node name, because every question
ADR 0003 raises is unanswerable in a trace that cannot say which instance it is
from. Sampling is parent-based and everything is sampled at first;
`HONEYCOMB_SAMPLE_RATIO` exists so turning it down is a dashboard change.

Off-the-shelf instrumentation is `opentelemetry_bandit` (the server span),
`opentelemetry_phoenix` (the route name, and LiveView `mount`, `handle_params`
and `handle_event`) and `opentelemetry_ecto`. There is no
`opentelemetry_req`/`_finch`: **outbound calls are spanned at Ravix's own
boundaries instead.** A client-level plug would name a span for a URL when the
useful name is the question being asked, and — the deciding reason — it cannot
tell `Tracks.get/2`'s two round trips from a stream that will still be open at
midnight.

**Everything Ravix traces itself goes through `Ravix.Trace`.** Nothing else in
`lib/` names `OpenTelemetry`. The single door is what makes three properties
enforceable rather than remembered:

  * `sanitize/1` runs over every attribute map. It is a whitelist of *shapes* —
    numbers, booleans, atoms and short binaries survive; a struct, a map, a
    list, a pid and a non-text binary are dropped — plus a blacklist of
    credential-ish *key names* for the case where the value is a plain string.
    So `span("fountain.get", %{client: client}, ...)` cannot ship the Fountain
    key, and `%{token: "ghs_..."}` cannot either.
  * `link/1` and `carrier/0` carry the context across a process hop, which is
    why a click's reads appear under the click. `RavixWeb.Live.Async.traced_async/3`
    wraps `start_async/3` so no page has to remember.
  * `untraced/1` turns tracing off for a process, by making a non-recording span
    current and letting the parent-based sampler drop its children. This is what
    keeps the prompt-queue sweep silent while each actual delivery, which runs
    in its own task and so has its own fresh context, still gets a trace.

**Product analytics and feature flags are PostHog, server-side only.** The
official `posthog` Elixir SDK: it has batched asynchronous senders, a no-op mode
when the API key is blank, a `test_mode` that keeps events in memory for
assertions, local flag evaluation behind a polling definition loader, and it
redacts its own secret through a custom `Inspect` — the same convention
`Ravix.Config` already uses. Ravix gets its own PostHog project, separate from
Fountain's.

**Eight events, all at a context boundary and all attributed to a person:** signed
in, project created, track opened, track closed, prompt sent, prompt delivered,
preview started, preview failed. `distinct_id` is the Ravix user id --- a UUID,
stable across a GitHub rename --- and the person properties are the GitHub login
and the account's creation date, never the email address.

Two things are deliberately absent from that list. **Agent turn completion**,
which is the event a funnel most wants, because a turn ends on a cluster-wide
follower that has no user attached and attributing it to the track's creator
would be inventing data; `prompt delivered` with its wait is the honest proxy,
and it says whether the prompt reached the agent. And **anything from the
browser**, for the reason below.

**Repository and branch names are sent. Prompt and transcript text is not.** The
first is a deliberate trade: "which repository was this?" is the first question of
every support conversation, no proxy answers it, and the cost is that customers'
private repository names travel to a third party. `Ravix.Analytics.repo/2` is the
single place that decision is made. The second is not a trade at all --- a
prompt's length and image count answer what its body would, and
`Ravix.Sprites.exec/4` already carries an argument count and never the arguments.
`Ravix.Redact.flat/1` sits under both as a backstop against a leak nobody
noticed, not as the judgement itself: a prompt body is a short text binary and
would survive it.

**There is no browser SDK.** No `posthog-js`, no autocapture, no session
replay. This is the one part of this decision that is about safety rather than
taste: Ravix renders agent transcripts, terminal output, file listings and
diffs, which is to say *the customer's source code*, and session replay would
ship it to a third party behind a masking configuration that has to be right
every time a template changes. Pageviews and flags do not need a browser SDK —
LiveView already knows which page somebody is on, and a flag read server-side
into an assign is one fewer round trip than a flag read in the browser. This
also keeps the existing invariant that the browser holds no business state, and
costs no change to the CDN allowlist. Flags will be read through one
`Ravix.Flags`-shaped boundary that returns a hard-coded default when PostHog is
unconfigured or unreachable, so a self-hosted deployment and `mix test` behave
without a PostHog account.

## Safe to run with nothing configured

This is a property worth stating separately, because it is what makes the
decision landable before an account exists, and because the obvious reading of
it is wrong. `traces_exporter: :none` stops spans *leaving*; it does not stop
them being *made*. `otel_batch_processor:on_end/2` buffers every sampled span
whatever the exporter is, and the SDK's default root sampler is `always_on` — so
the exporter setting alone would leave an unconfigured deployment building a
span, running `sanitize/1` and writing to an ETS table on every request, event
and query, then dropping the lot on a five-second timer. No egress, no log
noise, and real work for nothing.

So the unconfigured path is inert four times over, and only the first two of the
four are ours:

  * **Nothing is attached.** `Ravix.Trace.Setup.setup/0` asks
    `Ravix.Trace.enabled?/0` first and attaches no handler at all when the
    answer is no. This one is load-bearing and was missed at first: the sampler
    cannot help the off-the-shelf instrumentation, because a `:telemetry`
    handler runs *before* there is a span to sample.
    `OpentelemetryBandit.handle_request_start/2` calls
    `Plug.Conn.get_peer_data/1`, scans headers, formats an IP and builds seven
    or more attributes on every request; `OpentelemetryEcto` builds the
    statement attribute on every query. Measured with the sampler already off:
    **6.17µs a request and 6.64µs a query, entirely discarded** — against
    0.105µs and 0.039µs with nothing attached. A page load runs a request and
    twenty-odd queries, so that is real work charged to somebody who switched
    tracing off.
  * **`sampler: :always_off`** in `config/config.exs`, for the spans this
    application raises itself. An unsampled span is non-recording, and `span/3`
    attaches attributes only when the span records, so `sanitize/1` never runs.
    Measured on the inert path: **1.15µs** a span, down from 8.18µs before the
    attributes were moved behind that check, which is no more than an empty
    `with_span`. With tracing *on* a span costs about 6µs — either number is
    noise beside a Fountain round trip.
  * **`traces_exporter: :none`** means `otel_exporter:init/1` answers
    `undefined` without ever reaching `opentelemetry_exporter`, so no socket is
    opened, no DNS lookup happens and no endpoint or header is read.
    `Application.get_all_env(:opentelemetry_exporter)` is `[]`.
  * **The processor disables itself.** `init_exporter/2` on a `none` exporter
    calls `clear_table_and_disable/1`, which flips a `persistent_term` flag that
    `do_insert/2` checks: insertion is refused outright. This is the SDK's own
    belt to our braces, and it holds even if somebody later changes the sampler
    without changing the exporter.

What that leaves running on a deployment with no key is one `gen_statem`
cycling between idle and exporting every five seconds with nothing to export.
No handler is attached, so `mix phx.server` and a self-hosted deployment with
no Honeycomb account are the application they were before this decision rather
than slightly slower ones.

`enabled?/0` reads the sampler rather than a flag of its own, so there is no
second setting to keep in agreement: one line per environment decides both
whether spans record and whether handlers attach.

`config/test.exs` puts the sampler back, because `Ravix.TraceCase` needs spans
to read: parent-based over `always_on` rather than bare `always_on`, since
`untraced/1` works *by* the parent-based sampler dropping the children of an
unsampled parent, and there would otherwise be no suppression to test.

## Consequences

Traces, and nothing else. Honeycomb gets no metrics and no logs.
`RavixWeb.Telemetry` keeps `Telemetry.Metrics` and the VM poller, still with no
reporter attached. An OTLP log handler would put every `Logger` line through a
third party, which is a bigger surface than this decision covers.

**The gap worth knowing about: LiveView `render` is not traced, and per-event
render cost is the very thing #126--#130 were about.** LiveView emits a
`:telemetry` span for it, but from `handle_changed`, *after* the `handle_event`
span has closed — so a render span can never have a parent, and every one would
be a root trace. A transcript flush would file thousands of one-span traces for
a cost that is only legible as a distribution. It belongs in a metric, and a
metrics reporter is not part of this decision. `handle_info` and `handle_async`
are likewise unspanned: LiveView emits nothing for them, and `attach_hook/4`
runs *before* a callback rather than around it, so timing one through hooks
means opening a span in one stage and hoping `:after_render` arrives to close
it — and a message that changes no assign never renders, so that span leaks.
What is traced instead is the *work* those callbacks start, which is where the
Fountain round trips are.

Nine new dependencies arrive with the exporter, `grpcbox` and `chatterbox`
among them; they are compiled but unused on the HTTP/protobuf path.

Every deployment now has a way to send its traffic to a third party, and one
environment variable turns it on. That is the point, and it is also why the
sanitiser is tested as hard as it is, and why `Ravix.Sprites.exec/4`'s span
carries an argument *count* and never the arguments: that function is where the
terminal panel sends what somebody typed.

Two tests are `async: false` that would rather not be, because the in-memory
exporter is one global setting on the tracer provider.

## Alternatives considered

- **A Honeycomb-specific library, or `opentelemetry_req`** — the first buys
  nothing over OTLP, which Honeycomb speaks natively; the second cannot
  distinguish a request from a stream, which is the whole problem.
- **gRPC to Honeycomb** — supported, and the exporter's default, but one more
  long-lived connection to reason about on a platform that recycles containers.
- **`opentelemetry_liveview`** — the obvious dependency for the LiveView half,
  and abandoned: last released as `1.0.0-rc.4` in March 2022, twenty thousand
  recent downloads. `opentelemetry_phoenix` 2.x absorbed the same three
  callbacks and is maintained.
- **Contexts emitting `:telemetry` events, with one handler translating to
  OpenTelemetry** — the more conventional Elixir shape, and it keeps the vendor
  API out of `lib/ravix/`. Rejected because `:telemetry` cannot express nesting:
  a handler would have to maintain its own span stack to recover the
  parent-child structure that is the only reason to trace a page with five
  concurrent reads on it.
- **A browser SDK with masking rules** — see above. The failure mode is a
  customer's private repository in a third party's session recording, caused by
  a template change nobody thought to re-check.
- **Reusing Fountain's PostHog project** — one dashboard and one billing line,
  but flags and insights muddled across two products, and that project has
  session replay switched on.
- **Sampling the sweep away instead of `untraced/1`** — a ratio sampler drops
  the interesting traces at the same rate as the empty ones. Suppressing
  known-boring work and keeping everything else is the better trade at this
  volume.
