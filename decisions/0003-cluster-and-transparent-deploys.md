---
type: ADR
title: "Ravix runs on more than one instance: `:global` names, a cluster singleton, and a readiness-gated rolling deploy"
description: "Two or more instances in one region form an Erlang cluster over Render's discovery DNS; the transcript follower and preview server become `:global` names, the preview reconciler a cluster singleton, the prompt-queue sweep stays on every instance, and rotation is gated on a database-backed /readyz. Horde is deliberately not used; its tripwires are recorded here."
tags: [architecture, availability, deployment, otp]
status: stable
adr: "0003"
adr_status: "Accepted"
date: 2026-09-09
generated: { by: claude-opus/5, at: 2026-09-09T21:55:00-04:00 }
verified: { by: claude-opus/5, at: 2026-09-09T21:55:00-04:00 }
---

# 0003 — Ravix runs on more than one instance

**Status:** Accepted. Everything described here is built. The one line not
verified against Render itself is the `highAvailability` field's shape in
`render.yaml`, which is flagged in that file and settles on the first Blueprint
sync.

## Context

Ravix ran as exactly one instance, and `render.yaml` said why: the follower
registry, the machine cache, the prompt-queue sweep and the preview reconciler
were node-local singletons, so "a second instance would split preview ownership
and double the sweeps, silently." One container was therefore a single point of
failure, and every deploy was a gap in service.

Much of the groundwork was already there. Sessions, OAuth states and preview
grants are Postgres rows keyed by a token hash, so no request needs to reach a
particular instance and no sticky sessions are required. `PromptQueue.claim/1`
is an atomic conditional `UPDATE` and `PromptQueue.recover/0` reclaims by claim
age; its documentation already reasons about a deploy in which "two instances
overlap entirely."

What did not survive a second instance was anything keyed by a local `Registry`:

* `Ravix.Tracks.Follower` — one process per track holding Fountain's event
  stream open and broadcasting each event to a PubSub topic. PubSub spans the
  cluster, so a follower per instance means every reader sees every event once
  per instance.
* `Ravix.Previews.Server` — one process per track serialising starts, stops and
  rebuilds against a Sprites sandbox. Two of them is not a lock.
* `Ravix.Previews.Reconciler` — a fifteen-second pass whose contract is "never
  twice for one track".

And one thing was missing entirely: nothing recovers a reader whose follower
went away. On one instance that could not happen — the follower died with its
readers — so `Follower` monitors its subscribers and nothing monitors the
follower.

## Decision

**Instances form one Erlang cluster.** Render injects `RENDER_DISCOVERY_SERVICE`
into any service with more than one instance: a DNS name whose A records are the
instances' private addresses. `config/runtime.exs` hands it to the `DNSCluster`
already in the supervision tree, and `rel/env.sh.eex` switches the release to
`name` distribution with a node named `ravix@<that address>`. No libcluster: the
`dns_cluster` dependency was already present and does the same job for this
topology. `RELEASE_COOKIE` comes from the environment rather than the per-build
cookie a release bakes in, so the old and new instances of a rolling deploy form
**one** cluster instead of two — two clusters would each run a follower per open
track for the length of the drain.

**Processes that must not exist twice are named through `:global`**, behind
`Ravix.Cluster`. Registration takes a cluster-wide lock, so the second instance
to try a name is told the first one won. Supervision stays node-local: whichever
instance first needs a track starts the process under its own
`DynamicSupervisor`, and the name makes it reachable from anywhere.
`Previews.Server.busy?/1` reads its `:idle`/`:busy` flag from the owning
instance over `:erpc`, answering "busy" when it cannot ask — the only caller is
the reconciler deciding whether to queue work behind an operation it cannot see.

**The reconciler becomes a cluster singleton** (`Ravix.Cluster.Singleton`): every
instance starts a watcher, one wins the name and runs the tick, the rest monitor
the winner and take over when it goes. **The prompt-queue sweep deliberately does
not**, and keeps sweeping on every instance: its claim is atomic, so a duplicate
sweep cannot double-deliver, and prompt delivery is worth more than the takeover
window a singleton would introduce on that path.

**The reader recovers itself.** `Tracks.follow/3` returns the follower's pid;
`RavixWeb.TrackLive` monitors it and, on `:DOWN`, re-subscribes from the newest
event id it holds and re-reads the transcript. This is better than any handoff,
because the surviving cursor is the reader's, not the dead process's.

**Rotation is gated on readiness, not liveness.** `/healthz` still answers "the
process is up"; Render's health check now reads `/readyz`, which asks the
database. Deliberately not a cluster check: the first instance of a deploy has
no peers and would wait for a sibling that is waiting for it.

**Deploys drain.** The endpoint's `shutdown_timeout` is 20s and Render's
`maxShutdownDelaySeconds` is 30s — paired, and in that order, or the container
is killed mid-drain. The endpoint is the last child in `Ravix.Application`, so
it stops accepting before the followers and preview servers those pages talk to
go away.

**The database gets a standby.** Render HA requires at least one CPU, so
`ravix-db` moves from `0.1c-256mb` to `1c-2g`. Failover terminates every
connection and the standby answers at the same URL; `queue_target: 200` and
`queue_interval: 2_000` make requests during the gap wait rather than fail.

## Consequences

**Migrations are now expand/contract, not by preference.** `preDeployCommand`
runs `bin/migrate` while the *old* release is still serving every request. Add a
column before anything reads it; stop reading one before dropping it.

**Two instances can briefly hold the same `:global` name.** `:global` merges
name tables *after* nodes meet, so an instance that has just joined does not yet
know what its siblings registered — during a deploy, that is every new instance.
This is not hypothetical: it is what `Ravix.Cluster.DistributionTest` had to
wait out with `:global.sync/0` to become deterministic.

What happens next is the part that matters, and it dictated a design choice.
`:global`'s default resolver, `random_exit_name/3`, **kills** the loser. For a
supervised child that means a restart, a re-acquisition and another kill, and
enough of that inside five seconds takes `Ravix.Supervisor` — the whole instance
— down with it. That failure was reproduced in the test suite before it could
happen in production. `Ravix.Cluster.Singleton` therefore registers with
`random_notify_name/3` and handles `{:global_name_conflict, name}` by stopping
its worker and going back to watching. A duplicate costs one redundant
reconciliation tick, not an outage.

**A deploy is a reconnect, not a seamless handoff.** LiveView sockets on a
draining instance are closed at the end of the window and the browser reconnects
to another. Everything durable re-derives from Postgres on remount, and the
unsent prompt comes back from the browser's own storage
(`assets/js/hooks/composer.js`, which already did this for navigating away). A
new release changes the static asset hash, so LiveView forces a full page
reload; that is correct and not worth defeating.

**Caches stay per-instance, with one exception.** `Ravix.MachineCache` is brief
memoisation — a second copy is a cache miss, not a wrong answer. GitHub
installation tokens stay local: they are cheap to mint, GitHub allows several
outstanding, and moving a credential between instances to save a request is a
bad trade. GitHub *rate limits* are broadcast, because the limit is GitHub's and
counted per installation: without that, "twenty rows do not each discover the
limit" would become twenty per instance.

**The bill goes up**, deliberately: the web service doubles, and HA forces a
ten-fold CPU step on the database plan.

## Alternatives considered

- **Horde** — the obvious candidate, and Fountain already depends on it
  (`apps/fountain/lib/fountain/application.ex`), so familiarity argued for it.
  Rejected on the shape of the processes. Fountain's `ConversationServer` owns a
  provisioned sandbox, an ACP adapter and a runtime session id — state worth
  migrating, ~20s to rebuild, with a `Rehydrator` to restore the population.
  Ravix's per-track processes hold nothing worth migrating: the follower
  re-opens its stream from `last_id`, the preview server re-reads its row and
  generation. More decisively, `Previews.Reconciler` *is* the database-driven
  convergence loop a distributed supervisor would provide; adding Horde would
  mean two of them, disagreeing at CRDT speed. And `Horde.Registry`'s lookup is
  eventually consistent, which is how Fountain provisioned two sprites for one
  conversation when requests landed on different pods, and why
  `ConversationServer.await_registered/2` is a three-second polling settle
  window today. `:global` refuses the second registration instead.

  **Revisit Horde when any of these trips**, so that a reversal is a decision
  and not a discovery: (a) a process appears that holds expensive in-memory
  state with no database reconciler to rebuild it — Fountain's
  `ConversationServer` is exactly that; (b) registration passes human scale
  (thousands per second) or the cluster passes roughly ten nodes, where
  `:global`'s O(nodes) lock loses to a CRDT; (c) processes need spreading by
  policy rather than started on the instance that wants them
  (`Horde.UniformDistribution`). The deferred Mac runner (#11) is *not* a
  trigger: a connection pinned to one instance and addressable from all is
  registry work, which `:global` does.

- **Postgres ownership leases** — a per-track lease row with a heartbeat, so
  ownership survives a broken cluster. Correct without distribution, but it puts
  a lease check and its expiry races in front of every track operation, and adds
  a table and a sweep to maintain.

- **Consistent hashing over the member list** — deterministic owner per track,
  no leader, no lock. Rejected because ownership disagreement during membership
  churn is exactly the deploy window, and the failure it produces (two owners,
  briefly, with nothing arbitrating) is the one `:global` is here to prevent.

- **A build-baked release cookie**, letting old and new instances form separate
  clusters during a deploy. Simpler, and it avoids a mixed-version cluster
  entirely — but it reintroduces the duplicate follower for the length of every
  drain, which is the defect this ADR exists to remove. Inter-node messages here
  are plain maps and tuples, so the mixed-version risk is small.

- **A cluster singleton for the prompt-queue sweep too**, for one mechanism
  rather than two. Rejected: it would pause delivery for a takeover window on a
  path that is already safe to run everywhere, and prompt delivery is the least
  interruptible thing the application does.
