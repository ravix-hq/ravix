# Native preview runners checkpoint

Saved September 6, 2026, at the user's request to pause and resume later.

## Resume here

Continue gate 3 of [the brief](native-preview-runners-brief.md). The next action is
**live verification of the registered Mac runner with two tracks taking turns**.
Do not repeat workstation provisioning, Hello app creation, or the successful
native builds unless their evidence has changed. Do not treat this checkpoint as
proof that the registered daemon has run successfully.

Read [verification evidence](native-preview-runners-verification.md) for observed
results and [runner operations](../runner/README.md#registered-mac-and-durable-queue-hello-fixture)
for configuration, pairing, retention, and reset commands.

## Shipped and verified

- Android and iOS Hello previews previously worked through the real Mac, private
  Sprite Metro/backend, and authenticated Switchyard browser viewer. Browser
  input, scrolling, Fast Refresh and single-controller behavior were exercised.
  Detailed evidence and limitations are in the verification document.
- Durable runner registration and session queue implementation is committed in
  `337b041669c83e2792e0b25dd40e47510f670c67`. The viewer reconnect guard is
  `18f2a817407691b932394a201dcb2400540a0f47`.
- Last verified deployed image:
  `ghcr.io/managoat/switchyard:sha-18f2a817407691b932394a201dcb2400540a0f47`.
  CI workflows `34014778701` and `34014911283` passed. Rollout and public
  `/healthz` passed. Documentation was subsequently committed as `3f24676`.
- 321 tests passed, zero failed; one existing real-Chromium shared-browser test
  was skipped. TypeScript, Vite, Bun server bundle, and the local runner bundle
  passed. Protocol tests use local provider fixtures; adapter tests use mocked
  commands rather than real simulators.
- The signed-in Hello track showed **Pair a Mac runner**, and that action issued
  a code. Codes expire after five minutes; generate a new one when resuming.

The new path includes hashed persistent runner credentials, project allowlists,
revocation, a durable queue, request UUID deduplication, stable target affinity,
connection epochs, assignment generations, lease/deadline enforcement, and a
foreground Mac daemon. Managed Stop retains per-target device data while shutting
its device down and cleaning up Sprite services. Run-report retention is separate
from device data. An explicit local reset command removes a stopped owned target.

## Not yet verified or implemented

There is **no reported successful dedicated-account registration or live managed
two-track run** at this checkpoint. The last requested user action was the sudo
`--pair-runner` command below; no result was received before the pause. On resume,
check whether the user ran it in the meantime before issuing another pairing.

Gate 3 remains open. Real managed device-data retention, host reconnect/server
restart behavior, and queue handoff need live evidence. Automatic recovery after
an unclean local process exit, build-job dispatch, runner replacement/migration,
and broader cache retirement remain unfinished. The current engine allows one
global active preview; advertised per-runner build capacity is not build dispatch.

The product still accepts only `managoat/switchyard-expo-hello` under the existing
feature flag and consumes the pinned artifacts below. General project setup,
source export/build invalidation, and native agent helpers remain gate 4 work.
Track agents currently know the web-preview helper; they do not yet configure
or operate native previews themselves.

## Machine and saved artifacts

This checkout's Mac is the intended runner host. It is an Apple Silicon M4 Mac
running macOS 15.5, with the dedicated **standard** account `switchyard` (UID 502).
The user created that account and knows its password. Never request or save it.
The user invokes the provisioning wrapper with sudo; the runner itself executes
as the standard account with an empty inherited environment.

Already installed: Bun 1.3.11, Node, Java 21, Android SDK/system image 35 arm64,
scrcpy 4.1, Xcode 16.4, iOS Simulator runtime 18.6/22G86, and idb. The iOS build
helper handles the Xcode SDK 18.5/runtime 18.6 selection and restores its override.

| Artifact | Existing verified build |
| --- | --- |
| Android directory | `/Users/switchyard/.local/share/switchyard/builds/experiment-52e8255f-b89c-4596-846d-1aa6d6002041` |
| Android file | `app-debug.apk` |
| Android SHA-256 | `6bf899d7e847633cb70f02aa37b6c5ba8db32d07ff0e8cfb7bb5a168d92afe82` |
| iOS directory | `/Users/switchyard/.local/share/switchyard/builds/experiment-8bd7bc9e-f5e7-4822-a014-2c0a6aeb730b` |
| iOS file | `SwitchyardHello.app` |
| iOS SHA-256 | `375169f807696ad02ea5d82f1456b94142378e9f306eb5555bab55afe9abab2f` |
| Source digest | `fa3093b2e002fceef42b1243b932cc1415bbeb9afd82b80043699665840a09ff` |
| Lockfile digest | `f6b006e3c5d6271b6bbd9c0b81e84ed11f5f4c3d2c5b783e6fa41e2766d2e5ac` |

`/private/tmp/switchyard-runner.json` was prepared with mode 0600 and both exact
builds, account `switchyard`, name `Mac`, and the public Switchyard origin. It
contains no pairing code or credential. Temporary files may disappear; the
complete equivalent JSON is preserved in the runner README. Other useful but
non-durable local files are `/private/tmp/switchyard-expo-hello` (fixture checkout)
and `/private/tmp/switchyard-hello-source.json` (source snapshot).

## Exact next steps

1. Check current deployment and whether any preview or registered daemon is
   already running. An independently started iOS preview appeared during the
   last deployment; the follow-up rollout was held until it showed Stopped.
   Do not assume another active session belongs to this verification.
2. If registration has not happened, open the Hello track and choose **Pair a
   Mac runner** immediately before the user runs:

   ```sh
   sudo /bin/bash \
     /Users/jake/dev/managoat/demos/apps/switchyard/runner/scripts/provision-account.sh \
     switchyard --pair-runner
   ```

   Paste the fresh code at the prompt and leave the foreground command running.
   Registration stores the private reusable identity and config in the dedicated
   account's `~/.local/share/switchyard/managed/` directory. Do not print the token.
3. If already registered and cleanly stopped, reuse the identity:

   ```sh
   sudo /bin/bash \
     /Users/jake/dev/managoat/demos/apps/switchyard/runner/scripts/provision-account.sh \
     switchyard --serve-runner
   ```

   Do not register again merely because a pairing code expired. Stale locks or
   incomplete cleanup require inspection; do not remove them blindly.
4. Start a Hello preview from the browser; verify runner Online, assignment,
   greeting/backend, frames and input. Queue a second Hello track, stop the first,
   and verify handoff without new pairing. Return to the first target and verify
   its own persisted app/device data remains separate. React in-memory counter
   state alone is not a disk-persistence test. Exercise both Android and iOS.
5. Exercise disconnect/reconnect and server restart deliberately, checking that
   old generations cannot control devices and that cleanup completes before
   reassignment. Record actual session IDs, target IDs, reports and observations.
6. Close the remaining gate-3 gaps before claiming that gate complete. Then
   implement native track configuration and agent controls from gate 4.

No new devices, builds, registration, resets or preview runs were started while
saving this checkpoint. Existing five-minute codes are not useful resume state.

## Project coordinates

- Front door: <https://switchyard.demo.managoat.com>
- Private repository: `managoat/switchyard-expo-hello`
- Project: `e96fc271-182f-44df-a097-55db90ed2932`
- Existing track: `d792d4c2-26ac-4708-aef1-b1a2f21b44cd`
- [Open the Hello track](https://switchyard.demo.managoat.com/p/e96fc271-182f-44df-a097-55db90ed2932/t/d792d4c2-26ac-4708-aef1-b1a2f21b44cd)
- Branch/workdir: `jhgaylor/main`, `/home/sprite/work/main`
- Sprite: `fountain-50e06232-e92a6cf2`
- Application ID: `com.managoat.switchyard.hello`; scheme: `switchyard-hello`

## Repository continuity

The user's checkout `/Users/jake/dev/managoat/demos` contains substantial dirty
and untracked work, including unrelated shared-browser changes. **Do not reset,
stash, clean, or commit that checkout wholesale.** Native changes were committed
and pushed from isolated worktree `/private/tmp/sy-ios-integrated`, branch
`codex/switchyard-ios-release`, then the owned files were mirrored into the user's
checkout so its sudo wrapper uses the new runner code. That worktree is clean
except untracked dependency symlinks (`node_modules` and
`apps/switchyard/node_modules`); never stage those links.

Use that worktree if it still exists, or create a fresh worktree from current
`origin/main`. Check for concurrent changes before mirroring any resumed edits.
Earlier session authorization covered commits, pushing main and CI deployment;
this checkpoint does not authorize interrupting unrelated active previews.

Key implementation files:

- `shared/runners.ts`: bounded capabilities and assignment contract.
- `server/runner-store.ts`: durable registry, queue, affinity and fencing.
- `server/runner-coordinator.ts`: authenticated host control and scheduling.
- `server/native-experiment.ts`: existing proven engine plus managed bridge.
- `runner/registered-runner.ts`: registration, private identity and host loop.
- `runner/preview-experiment.ts`, `runner/adapters/experiment.ts`: native runtime
  with managed per-target retention.
- `runner/state.ts`, `runner/reset-target.ts`: locks, report bounds, explicit reset.
- `src/components/NativePreview.tsx`: pairing, runner status, queue and viewer.

Do not lose the earlier unresolved evidence: intermittent Sprite transport
failures and old service definitions reappearing were observed before the
successful iOS run. Recovery/cleanup tests do not establish that those provider
issues cannot recur. Phone-browser WAN measurements, mobile Safari, sustained
latency/reliability and several platform controls also remain unverified.
