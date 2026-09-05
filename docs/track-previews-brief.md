# Track previews

Audience: coding agent implementing the next Switchyard feature.\
Status: product direction agreed; implementation pending.\
Date: September 5, 2026

## Outcome

Implement authenticated, durable app previews for Switchyard tracks. The user
must be able to queue a change, close the laptop, open the result on a phone,
and send a correction from the same track.

Fountain already gives the project a persistent remote workspace containing the
checkout, dependencies, and agent changes. Previews turn that workspace into a
place to try the result. The preview shows the track's live working copy,
including uncommitted changes; it is not an immutable release artifact.

## Start here

Read the current checkout before editing; file references below are relative to
`apps/switchyard/`. Preserve existing terminal execution and durable prompt
queue behavior.

| Entry point | Use |
| --- | --- |
| `README.md` | Project identity, shared machine, worktree, and access model |
| `server/sprites.ts`, `server/terminal.ts` | Provider client and existing bounded execution; add managed service/tunnel support rather than extending command timeouts |
| `server/tracks.ts` | `machineOf`, `spriteFor`, and track cleanup |
| `server/context.ts`, `server/stream-access.ts` | Authorization and access revocation patterns |
| `server/db.ts`, `shared/api.ts`, `server/app.ts` | Additive persistence, typed contracts, and routes |
| `server/projects.ts`, `server/index.ts` | Project rebuild/archive and server startup integration |
| `src/components/Run.tsx`, `src/components/ProjectSettings.tsx` | Existing run controls and project configuration |
| `mock/`, `server/*.test.ts`, `k8s/` | Local fixtures, regression tests, and deployment configuration |

Use existing authorization helpers. Project defaults remain owner-controlled;
track members may operate previews within their existing execution permissions.
Reject preview operations for closed tracks. Keep provider details in server
code. Suggested new modules are `server/previews.ts` for orchestration and
`server/preview-gateway.ts` for routing; adapt these boundaries to the code.

## First milestone: prove the route

Run two different versions of a small app in two Demos tracks. Give each a
private preview URL and verify that both load simultaneously and hot reload
works through the gateway. Also verify that a signed-out visitor cannot reach
either app.

Do this before building the complete UI. It tests the central constraint:
tracks share a project machine, but need independent ports, routing, and browser
origins. Confirm the deployed Sprites API supports the required service and
tunnel operations during this milestone.

## Experience

Save a project default for the app directory, startup command, and readiness
path, with a per-track override. Switchyard allocates a port and supplies
`$PORT`; the startup command must honor it. Monorepos select the app directory
explicitly.

The track offers **Open preview**, **Restart**, **Stop**, and **Logs**. Opening
a stopped preview starts it and shows progress until its readiness check
passes. States are Stopped, Starting, Ready, and Failed; failures expose useful
startup logs. A running process alone does not mean Ready.

Open in a new tab initially, with a link back to the track. Show that this is a
live working copy so the user understands that agent edits can change it.

## Implementation

**Configuration and supervision.** Persist the track's configuration, allocated
port, service identity, sandbox identity, desired state, and last activity.
Allocate ports uniquely within each machine and fail clearly on a collision;
do not let a dev server silently select another port. Extend the existing
Sprites client to manage a named service rooted in the track's worktree.
Sprites services already provide startup, crash restart, explicit stop, and
logs. Reconcile saved intent with actual service state after Switchyard
restarts, and stop repeated startup failures from becoming an endless crash
loop. [Sprites services](https://docs.sprites.dev/concepts/services/)

**Routing.** A preview gateway authenticates the visitor, resolves the track to
its current sandbox and allocated port, and forwards HTTP and WebSocket traffic
through a private Sprites TCP tunnel. WebSocket upgrades, streaming, and
backpressure are required for dev servers and hot reload. Sprites exposes only
one built-in HTTP service route per machine, so that route cannot represent
every track independently. [Services routing](https://docs.sprites.dev/concepts/services/),
[TCP proxy](https://docs.sprites.dev/api/dev-latest/proxy/)

**Access.** Give each track a hostname on a dedicated preview domain, separate
from Switchyard's application origin. Exchange a short-lived, single-use ticket
from Switchyard for a host-scoped preview session. Enforce track membership on
requests and WebSocket connections, including revocation of existing sessions.
Keep gateway cookies and provider credentials out of upstream app requests.
Resolve destinations on the server; the browser cannot choose arbitrary ports
or hosts. Distinct origins isolate browser state; tracks still share a machine
and are not separate security sandboxes.

**Lifecycle.** Opening a preview wakes the workspace and starts its service.
Active viewing holds an expiring activity lease; inactivity releases the lease
and eventually stops that preview. Coordinate this with Fountain's parking
logic and Sprites' suspension behavior. Services alone do not keep a Sprite
awake; expiring Tasks can hold it while needed. Avoid health polling that wakes
idle machines. Stop and remove services when tracks close, and reconcile
sandbox replacements. Stopping one preview must preserve other tracks and
agent work. [Sprite activity holds](https://docs.sprites.dev/keeping-sprites-running/)

## Scope and delivery

Implement in this order:

1. Prove authenticated routing for two tracks, including hot reload. Record the
   actual service/tunnel protocol and any provider limitations you encounter.
2. Add saved configuration, idempotent service operations, port allocation,
   startup reconciliation, activity leases, and cleanup. Serialize conflicting
   start/stop/restart operations per track; reject stale results after a
   configuration or sandbox change.
3. Add track controls and project settings, then verify the mobile feedback
   loop. Provide an explicit unavailable state when provider support is absent.

The first version supports Sprites and one exposed HTTP endpoint per track.
A project startup script can launch supporting processes; additional fixed
ports and writable app data must also be scoped per track.

Public sharing, embedded previews, automatic framework detection, immutable
preview snapshots, and a general service orchestration system are later work.
Deployment requires a preview domain, wildcard DNS/TLS, and gateway routing.
Inspect existing infrastructure before selecting domain values. Verify the
Fountain lifecycle integration rather than assuming a provider task prevents
Fountain itself from parking the workspace. Document any required Fountain
change and implement within the available authorized scope. If infrastructure
is unavailable, complete local implementation and tests and state precisely
which live checks remain blocked; do not report those checks as passed.

## Acceptance criteria

- Two Demos tracks serve distinct changes simultaneously, with working hot reload.
- A queued UI change finishes with the laptop closed; its preview opens on a
  phone and the user can return to the track to request a correction.
- Unauthorized visitors cannot access previews, and removing access terminates
  existing preview sessions and connections.
- Service crashes and Switchyard restarts recover predictably; failed startup
  shows actionable logs.
- An idle preview resumes on demand. Stopping or closing one track leaves
  other previews and agent work intact.

## Verification and handoff

Add behavior tests for authorization and revocation, concurrent port allocation,
repeated/conflicting service operations, restart reconciliation, and lifecycle
cleanup. Test HTTP streaming and WebSocket forwarding at the gateway boundary.
Use the actual two-track browser exercise to prove hot reload; mocked provider
responses alone do not establish it.

Run `bun run test`, `bun run build`, and `git diff --check` from
`apps/switchyard/`. Update the README with configuration and operating steps.
Hand off the implementation with test results, live verification evidence,
required deployment settings, and any unresolved limitations. Follow the active
task's authorization for PR creation, merging, and deployment; this brief
defines implementation scope, not additional publishing permission.
