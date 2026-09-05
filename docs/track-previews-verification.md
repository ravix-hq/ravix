# Track previews: verification and deployment handoff

## Live follow-up after merge

The deployment follow-up (#41) also passed CI, rolled out, and obtained its
wildcard certificate. Chrome's normal **Open preview** flow loaded both Demos
tracks over their real HTTPS hosts. A file edit hot-reloaded elkhart to version
2 while hamlet stayed at version 1. An unsigned HTTPS request returned 401;
the back link returned to the correct signed-in track. Stopping hamlet left
elkhart Ready. The two temporary overrides were then cleared.

Cleanup exposed a deployed-provider detail absent from the original fixture:
stopping Vite can leave service state `failed` with exit code 143, and a second
stop returns HTTP 409 with `service is not running`. Treat that exact response
as a successful stop; other stop conflicts and all start conflicts still fail.
Regression tests cover both cases. This also fixes clearing configuration and
restart/cleanup after an explicitly stopped process.

On September 5, PR #40 merged as `7245ff867639da1285f3769bcdf4d2d83851544d`.
CI and the image build passed and the matching image rolled out successfully.
Following the user's request to verify in Chrome, the pod-local harness ran
against the actual Demos Sprite. Both named services reached HTTP readiness;
expiring Tasks and private TCP tunneling succeeded.

Chrome denied both preview hosts before a ticket was exchanged, then loaded
hamlet and elkhart simultaneously. Editing elkhart changed its already-open
page from version 1 to version 2 through Vite hot reload, while hamlet stayed
at version 1. This used real Sprites services/tunnels through localhost port
forwarding, not the mock provider. The temporary services and fixture files
were removed afterward. A pod replacement during setup also required cleanup
of the first pair of fixture services, which completed successfully.

The rollout still used the base manifests without the optional gateway.
Wildcard DNS was verified to resolve to the existing ingress, so the
follow-up deployment includes that reviewed gateway, TLS certificate and
preview environment settings in `k8s/`. Production HTTPS verification follows
certificate readiness. The earlier record below describes the original PR's
verification state; its live-approval blocker was superseded by this request.

To test through the actual production controls, the harness also accepts
`--fixtures-only`: it creates the two fixture directories and records their
ownership in the disposable database, then exits without starting services.
Configure each track to use `.switchyard-preview-proof` and the printed Vite
command. Stop and clear those track overrides before running `--cleanup`.
Physical-phone and a complete Fountain parking/correction cycle remain untested.

## Original PR handoff

September 5, 2026. Implementation is ready for review. Production deployment
and the live acceptance exercise are still pending. No live service was created
and no deployment or DNS change was applied during implementation.

## Evidence

| Requirement | Completed evidence | Remaining live check |
| --- | --- | --- |
| Independent track routing and HMR | Browser opened two actual Node/Vite apps through the gateway's mocked Sprites transport, with separate track hosts and ports. Conway changed to version 2 while Hamlet remained version 1, without a manual reload. Vite reported connected on both. | Repeat on Demos hamlet/elkhart using the deployed Sprites TCP proxy. |
| Durable feedback loop | Queued a Conway correction through the ordinary composer, immediately closed the Switchyard tab, then observed version 2 in the open preview. SQLite recorded the prompt delivered and the server remained healthy. | Closed laptop, physical phone, return to track, then a second queued correction against live Demos. |
| Mobile controls | At a 390 × 844 browser viewport, followed the preview's Back to track link, submitted a correction, and reopened Conway at version 3. | Physical phone and mobile browser networking/authentication. |
| Private access and revocation | Gateway tests reject unsigned HTTP/WS, cross-host and expired tickets, ticket replay, foreign-origin writes/upgrades and removed members. Removal/reinvite does not resurrect a session. Sign-out and revocation terminate existing HTTP streams and WebSockets. | Signed-out browser profile and live removal with established connections. |
| HTTP and WebSocket transport | Real socket tests cover HTML injection, streaming cancellation, 800 KB uploads, text/binary WebSockets and negotiated subprotocols. An 8 MiB slow-reader test checks bounded tunnel buffering and complete delivery. | Actual Sprites framing and ingress buffering/timeouts. |
| Durable service supervision | SQLite/fake-provider tests cover concurrent unique ports, cross-connection constraints, repeated starts/restarts, stop during startup, changed configuration, readiness, crash limits, process restart reconciliation, sandbox replacement, failed-stop retry, idle behavior and peer-preserving cleanup. | Live process crash, Switchyard restart, idle suspension/resume and peer agent continuity. |
| Unavailable provider | Missing configuration produces an explicit unavailable response; unsupported service/task operations retain actionable failure state. | Actual unsupported provider deployment. |

Local browser fixtures are genuine Vite processes with file watching and HMR;
the Sprites control plane and TCP relay are local mocks. This proves browser,
gateway and dev-server compatibility, **not** the deployed provider protocol.

Validation commands from `apps/switchyard/`:

```sh
bun run test
bun run build
git diff --check
bunx tsc --noEmit --strict --skipLibCheck --target ES2022 --module ESNext \
  --moduleResolution bundler --types bun \
  mock/server.ts mock/previews.ts scripts/preview-live-proof.ts
```

The test suite passed **199 tests across 23 files**, with 1,275 assertions.
The production TypeScript check, Vite build and server bundle passed. The
bundle was also run locally with the mock stack. The optional Kubernetes
overlay renders with `kubectl kustomize apps/switchyard/k8s-previews`.
Docker image execution was not checked because the local Docker daemon was
unavailable; CI must build the image from the generated `dist/` and
`dist-server/` directories.

Closing the browser during the feedback exercise exposed an existing Bun
transcript-stream crash: reporting an AbortError after the client had already
abandoned the response could terminate the server. Client disconnect now closes
that output cleanly while still cancelling upstream work. Authorization loss
continues to error and discard queued output. Both behaviors have regression
coverage, including actual HTTP disconnects.

## Provider protocol and runtime constraints

Read-only requests against the live deployment confirmed that Demos resolves
to Sprite `fountain-50e06232-6983bd17` and that its services endpoint answers
HTTP 200 with an empty list. A bounded command confirmed Node/Bun and the
hamlet Switchyard checkout with Vite dependencies are present. These checks
did not exercise service creation, Tasks or a TCP tunnel.

Implementation follows the official [services API](https://docs.sprites.dev/api/dev-latest/services/),
[TCP proxy API](https://docs.sprites.dev/api/dev-latest/proxy/) and
[activity Tasks documentation](https://docs.sprites.dev/keeping-sprites-running/).
The official Sprites Go client's proxy and service implementations were also
inspected to cross-check framing and operation paths.

- Service definition is `PUT /v1/sprites/:sprite/services/:name` with `cmd`,
  `args`, `dir`, `env` and `needs`. `http_port` is deliberately omitted so the
  machine's public HTTP route never points at a track preview. Start/stop use
  POST action endpoints; removal uses DELETE on the named service. Monitoring
  is bounded with `duration=1s`. Logs come from the managed service log file.
- The private `/proxy` WebSocket receives a text JSON message
  `{"host":"127.0.0.1","port":allocatedPort}`, acknowledges with
  `{"status":"connected"}`, then transports TCP bytes in binary frames.
  The provider handshake validates the WebSocket accept value. The browser
  never supplies the provider destination or its authorization header.
- Activity uses the in-Sprite Unix socket `/.sprite/api.sock`, a named Task
  with `{"expire":"2m"}`, and explicit DELETE on stop. It requires `curl`
  and expiring Task support; unsupported holds fail startup clearly.
- Bun's built-in `undici`/`ws` compatibility paths did not provide the custom
  TCP stream and outbound framing APIs needed here. Aliased npm packages
  `undici-node` and `ws-node` supply them. The browser-side upgrade uses Bun's
  native `ws` adapter; writing a raw HTTP 101 to Bun's compatibility socket
  did not establish a browser WebSocket. The production server is bundled so
  the container includes the full npm transports.
- Streaming queues use backpressure. Browser WebSocket messages are limited
  to 1 MiB and pending browser-to-app writes to 2 MiB; overload closes the
  connection. Compression negotiation is disabled on the inner WebSocket.

## Fountain parking assessment

The inspected Fountain checkout matched the deployed image revision
`2b25ec42a39d8368c04b7dffe0d2cd8859260145`. The following is a source-based
assessment; a real idle interval has not been exercised.

`apps/fountain/lib/fountain/conversations/lifecycle.ex` can mark an idle
conversation's sandbox suspended after its own idle threshold. It does not
consult Sprites Tasks. Its `machine_gone` notification makes the conversation
server drop its connection and clear its handle. The sandbox reaper has its
own parking decisions as well. Therefore a provider Task cannot be described
as preventing Fountain's bookkeeping park.

The deployed dependency's Sprites adapter,
`deps/managoat_sandbox/lib/managoat/sandbox/sprites.ex`, implements `suspend`
as a successful no-op. Its resume path probes the Sprite. On this version,
Fountain parking therefore does not physically stop the named service; the
Sprite's own expiring Task controls whether the provider may sleep. Preview
operations resolve the machine independently, and the next queued correction
uses Fountain's normal conversation reattachment path.

No Fountain change was made. This appears sufficient for the current
Sprites-only implementation, but live parking/resume and the subsequent
correction remain release checks. If a future adapter's `suspend` actually
stops the machine, Fountain must expose an expiring external-activity lease
and consult it in **both** conversation parking and the sandbox reaper. Merely
extending the provider Task would then be insufficient.

## Deployment and pending live exercise

The existing app host is `switchyard.demo.managoat.com`. No preview wildcard
DNS/certificate/route was present during inspection. The optional
`k8s-previews/` overlay proposes `*.preview.switchyard.inevitable.fyi` on the
existing Traefik ingress and `letsencrypt-production` DNS01 issuer. It is a
reviewable configuration, not an applied change. See the README for settings,
startup command examples, CSP requirements and operating limits.

Automatic approval review rejected copying live provider credentials to a
local file. A replacement exercise was prepared that keeps credentials inside
the Switchyard pod. Approval review then rejected that exercise's disposable
files and private services on the two shared Demos tracks without explicit
approval. The approval question is pending. These live checks are not passes.

`scripts/preview-live-proof.ts` is the prepared operator harness. It reads the
production SQLite database read-only, uses a separate database under
`/tmp/switchyard-preview-proof`, creates `.switchyard-preview-proof` fixture
directories in hamlet/elkhart, and launches two private Vite services. It
refuses existing fixture directories. It is deliberately specific to those
selected tracks, and requires their existing Vite installation.

After live-fixture approval, build it locally, copy only the bundle to the
current pod, and run it there. Do not export the pod's credentials:

```sh
# From apps/switchyard, with POD set to the current Switchyard pod name:
bun build scripts/preview-live-proof.ts --target=bun --outfile=/tmp/switchyard-preview-proof.js
kubectl -n switchyard cp /tmp/switchyard-preview-proof.js "$POD":/tmp/switchyard-preview-proof.js
kubectl -n switchyard exec -it "$POD" -- bun /tmp/switchyard-preview-proof.js
# In another terminal, bind only localhost:
kubectl -n switchyard port-forward pod/"$POD" 18082:18082 18083:18083
```

Open `http://localhost:18083`. The launcher and gateway listen only on pod
loopback and are accessible through the local forward. The launcher grants
synthetic test access; it is not a production sign-in route and must never
receive ingress. Open both tracks, edit one and observe HMR while the other
stays unchanged. Test the unsigned links in a separate signed-out profile
**before** granting it a test session. Stop the harness, then remove its
services and owned fixtures while the disposable database still exists:

```sh
kubectl -n switchyard exec "$POD" -- bun /tmp/switchyard-preview-proof.js --cleanup
```

Inspect cleanup output and the provider service list. Only after cleanup,
remove the disposable pod database and bundle. A subsequent run needs a fresh
disposable database. This routing harness alone does not establish the actual
GitHub-authenticated mobile correction loop or the Fountain idle interval;
those need the deployed feature with wildcard HTTPS and an actual phone.
