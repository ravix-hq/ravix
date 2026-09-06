# Native preview runner verification

Date: September 5–6, 2026. Status: **Deployed Android preview exercised through
real Sprite Metro, Mac emulator and Chrome. Core live path works; gate-2
compatibility, reliability and performance checks remain open.**
The [brief](native-preview-runners-brief.md) remains the full implementation contract.

## Implemented

- Companion CLI: read-only `doctor` and isolated Android/iOS `experiment` commands.
- Automatic discovery of this Mac's SDK, Homebrew Java and user-local idb tools.
- Private AVD/simulator sets, explicit device identity, exclusive acquisition,
  bounded subprocesses, cancellation and targeted device cleanup.
- Settings swipe/tap/text fixture, screenshots, H.264 file recording and private
  per-command diagnostics. Reports distinguish successful commands from visual proof.
- Installed toolchain recorded in [toolchain-macos.json](../runner/toolchain-macos.json).

The milestones below record the work in order. The latest paired preview
implementation, deployment and live observations are described at the end.

## Confirmed workstation and provisioning

The user confirmed this checkout's Mac as the intended workstation and authorized
Android/idb installation. Experiments ran under `jake` in private disposable
state directories. The user subsequently created the standard `switchyard` account (UID 502). The user
ran the provisioning command: home creation and tool installation completed,
but the final doctor check failed. The user supplied the blocker summary:
iOS has no blockers; Android emulator version and acceleration probes each
timed out at 15 seconds. The cause is unconfirmed. The updated diagnostic runs
emulator probes sequentially with 60-second deadlines and records timings;
`provision-account.sh switchyard --check` refreshes it without reinstalling tools.
The user supplied a successful dedicated-account recheck: both blocker lists
are empty. Emulator version took 5,874 ms, acceleration 322 ms, and AVD listing
18 ms. Hardware acceleration reports Hypervisor.Framework on macOS 15.5. The
empty AVD list is expected before creating owned devices.
These experiments executed installed SDK tools and system Settings only.

| Item | Installed / observed |
| --- | --- |
| CPU / architecture | Apple M4, 10 cores, arm64 |
| Memory | 16 GiB |
| macOS | 15.5, build 24F74 |
| Xcode | 16.4, build 16F6 |
| iOS runtime / profile | iOS 18.6 / iPhone 16 |
| OpenJDK | Homebrew OpenJDK 21.0.12.1 |
| Android SDK | `~/Library/Android/sdk`, approximately 5.5 GiB |
| SDK command-line tools | 23.0; Homebrew package 15859902 |
| Platform-tools / emulator | 37.0.1 / 37.1.11 |
| Compile SDK / build-tools | API 36 / 36.0.0 |
| Android image / profile | API 35 Google APIs ARM64, revision 9 / Pixel 7 |
| Emulator acceleration / renderer | Hypervisor.Framework / hardware GLES, Vulkan disabled; 4 cores, 4 GiB RAM |
| scrcpy | 4.1 (Homebrew 4.1_1) |
| idb client / companion | fb-idb 1.5.2 in uv Python 3.12 environment / universal companion 1.1.8 |
| CocoaPods / FFmpeg | 1.17.0 / 9.0.1 |

Both `doctor` prerequisite checks pass outside the execution sandbox. Raw inventory
is private at `/private/tmp/switchyard-runner-provisioned.json`. CoreSimulator
requires access outside that sandbox. `livePreviewVerified` remains false.

SDK Manager accepted the standard Android package licenses during installation.
Its command-line tools were installed into the same SDK root as the system image:
Homebrew's separate `avdmanager` otherwise reported no valid system-image paths.
The runner supplies Java/SDK paths to child processes; no shell profile or system
Java symlink was changed. Homebrew installed/updated required dependencies.

Current Meta companion 1.5.2 requires Xcode 26. We retained this Mac's Xcode and
installed official companion 1.1.8, validating its archive against Meta's
[historical formula checksum](https://github.com/facebook/homebrew-fb/blob/c038679/idb-companion.rb).
Its URL, SHA-256 and installation layout are recorded in the runner instructions.
Only the exercised client/companion operations are established to interoperate.

## iOS live evidence

Reviewed experiment: `2319e3e7-48a8-4b81-9c78-e70c8c6aecb1`, retained privately in
`/private/tmp/sy-native-ios/experiment-2319e3e7-48a8-4b81-9c78-e70c8c6aecb1`.

- A new device in an experiment-owned simulator set booted without workstation UI.
- `before.png` shows Settings; `swipe.png` shows the scrolled settings list.
- `after.png` shows search text **Switchyard** and its no-results screen. This
  confirms swipe, tap and ASCII text input; iOS applied capitalization.
- idb captured H.264 at 1178 × 2556, 366 frames over 18.135 seconds. FFmpeg decoded
  every frame with the input timebase preserved. Decoded timestamps strictly increase.
- A plain FFmpeg null-output invocation rounded variable frame timestamps to an
  unsuitable output timebase; `-fps_mode passthrough -enc_time_base demux` avoids
  those muxer timestamp warnings. No decoder failure was observed.
- Boot: 85.230 s; Settings preparation: 10.697 s; capture/input: 20.326 s;
  cleanup: 3.862 s. These are individual experiment phase measurements.
- Cleanup shut down and deleted only the created UDID, terminated its companion,
  and released the experiment lock.

idb describes a 1179 × 2556 screen with density 3 (393 × 852 points); the encoder
uses an even width, one pixel narrower. Future input mapping must account for
this. This older companion also reports `x86_64` in `describe` on the ARM64 host;
that field is not suitable for selecting build architecture without independent
runtime verification. No simulator app artifact was built or installed here.

The first iOS attempt captured Home before Settings was ready. Preparing Settings
before capture and extending the recording window produced the reviewed evidence.

## Android live evidence

Reviewed experiment: `6e3d5e0e-0e89-4f1f-8710-695beb142728`, retained privately in
`/private/tmp/sy-native-android/experiment-6e3d5e0e-0e89-4f1f-8710-695beb142728`.

- A fresh Pixel 7 AVD booted without a workstation window, with explicit 4 GiB
  RAM and four cores, hardware GLES (`-gpu host`) and Vulkan disabled.
- `before.png` shows Settings; `swipe.png` shows the list scrolled down to
  Location and Safety & emergency. `tap.png` shows search; `after.png` visibly
  contains **switchyard** and the no-results screen with the keyboard open.
- A fresh UI hierarchy independently contains the injected search text. The tool
  requires an actual successful dump, because uiautomator can exit zero on error.
- scrcpy 4.1 produced H.264 at 576 × 1280, 236 frames over 18.350489 seconds.
  FFmpeg decoded the complete recording without errors using the input timebase.
- Boot: 24.642 s; Settings preparation: 16.830 s; capture/input: 21.904 s;
  cleanup: 2.029 s. This is one first-boot measurement, not a startup guarantee.

Early runs exposed two distinct problems. First, `sys.boot_completed` and a
successful Settings launch did not establish that Settings was visible; the
experiment now waits for its UI content. Second, the default device resources
produced inconsistent input and a system-not-responding dialog. The successful
run used the explicit resources above. Hardware GLES with Vulkan disabled is an
option in Android's [Apple Silicon graphics troubleshooting guidance](https://developer.android.com/studio/run/emulator-troubleshooting).
These experiments do not isolate a single cause or prove long-running stability.

The search bar moves as the header collapses, so the experiment reads its current
bounds before tapping. It requires the resulting text in the hierarchy and
retains screenshots for separate visual review. The CLI still does not mark a
browser stream or Expo application as verified.

Every completed Android experiment cleaned up its owned emulator and AVD. No
personal emulator/simulator was adopted or erased, and no global ADB shutdown
was issued. Private reports remain under `/private/tmp/sy-native-android`.

## Automated checks

- Runner behavior tests: **32 passed**, including literal arguments, output and
  deadline bounds, cancellation, graceful capture termination, read-only inventory,
  malformed output, private state, exclusive acquisition, retained-evidence quota,
  installed-image discovery, tool environment, serialized emulator probes with
  retained failures/timings, occupied devices, version mismatch
  and cleanup confined to the experiment's device. Runtime tests also cover pinned
  artifact validation/tampering, XML selectors, ownership gates, serial-scoped
  app operations, and loopback binding.
- Switchyard suite: **265 passed, 0 failed**, 1,631 assertions across 30 files.
  Existing local HTTP/WebSocket tests require execution outside the sandbox.
- Switchyard production build and typechecking: **passed**.
- Earlier workspace-wide typechecking: all 18 packages passed.

Private current logs: `/private/tmp/switchyard-native-access-tests.log` and
`/private/tmp/switchyard-native-access-build.log`. Mocked behavior tests complement
the separate native observations; they do not prove browser compatibility.

## Remaining gates and limitations

| Gate | Android | iOS |
| --- | --- | --- |
| Mac confirmation / SDK provisioning | Complete | Complete |
| Dedicated native build account | Android build and local runtime passed | Installed; prerequisites pass, live test pending |
| Native capture/input experiment | Capture, swipe, tap and ASCII text reviewed | Capture, swipe, tap and ASCII text reviewed |
| Encoded stream in Chrome/Safari and a phone browser | Not implemented | Not implemented |
| Expo development build, private Metro/HMR and app backend | APK, local Metro/backend and Fast Refresh passed; Sprite path pending | Not implemented |
| Pairing, assignments, jobs, leases, reconnect, capacity | Not implemented | Not implemented |
| Browser/agent controls and controller handoff | Not implemented | Not implemented |
| Working-copy snapshots, build invalidation and cache | Local source/build experiment implemented; Sprite transfer/invalidation/cache pending | Local snapshot format available; iOS build path pending |
| Authorization, revocation and session lifecycle suite | Not implemented | Not implemented |
| Delivered FPS, median/p95 interaction and WAN bandwidth | Not measured | Not measured |

File frame counts include idle periods and are not delivered browser FPS. No
interaction-latency, concurrency, rebuild-time or smoothness target is established.
The experiments do not exercise Unicode text, rotation, multi-touch, navigation
controls, browser pointer cancellation, software decoding or scrcpy/Tango framing.
Screenshot polling is not used as evidence of responsive live preview.

The private [Hello World Expo SDK 54 fixture](https://github.com/managoat/switchyard-expo-hello)
is on `main` at `68fabcd`. Typechecking, Expo dependency compatibility, Android/iOS
Metro bundle export and loopback backend responses passed. The first Android
native build passed under `switchyard` on September 5, 2026, as reported by the
user from the local administrator invocation. The staging checkout is `/private/tmp/switchyard-expo-hello`.
The prepared snapshot has 14 files and digest
`fa3093b2e002fceef42b1243b932cc1415bbeb9afd82b80043699665840a09ff`.
The `--build-hello` helper stages it and compiles an Android debug development
APK under `switchyard`, with fixed commands, bounded resources, retained logs,
package/ABI validation and artifact/source digests. All six build phases passed; compilation took 519,151 ms (8 min 39 sec).
The retained build is
`/Users/switchyard/.local/share/switchyard/builds/experiment-52e8255f-b89c-4596-846d-1aa6d6002041`.
Its `app-debug.apk` is 53,812,913 bytes, package
`com.managoat.switchyard.hello`, ABI `arm64-v8a`, SHA-256
`6bf899d7e847633cb70f02aa37b6c5ba8db32d07ff0e8cfb7bb5a168d92afe82`.
Lockfile digest:
`f6b006e3c5d6271b6bbd9c0b81e84ed11f5f4c3d2c5b783e6fa41e2766d2e5ac`.
The report explicitly leaves native runtime, Metro and browser verification false. Snapshot tests cover
working-copy edits/deletions, workspace files, source churn, traversal, links,
case collisions, hash tampering and credential-free build environments.
The gate must prove a staged working-copy development build, private
Sprite Metro, a backend request, browser control, an uncommitted edit and signed-out
denial before the media contract and product sessions are treated as complete.


## Prepared Android runtime preflight

`--run-hello` now stages a bounded runtime experiment under the dedicated account.
It requires the explicit build directory and pinned APK hash, installs only on a
fresh owned emulator, and checks rendered UI hierarchy for the greeting, counter,
ASCII name entry, a nonce-bearing local backend response, an uncommitted greeting
edit with React state preserved, and scroll completion. The staged counter label includes its value for accessibility assertions; its
runtime source digest is recorded separately. It retains screenshots,
a capture file and command diagnostics, restores the staged `App.tsx`, stops its
local services, and deletes its emulator. Cleanup uncertainty retains both locks.
The first runtime invocation under `switchyard` **failed to observe the greeting**;
see the retained failure below.

A separate local Metro preflight under `jake` passed: SDK 54 served its Android
development manifest and 4,647,533-byte bundle with HTTP 200, advertised
`127.0.0.1:19381`, and `lsof` confirmed a listener only on that loopback address.
The process was stopped afterward. The runner explicitly preloads a listener
restriction because this SDK's `--localhost` controls advertised URLs, while its
Metro listener otherwise receives an undefined host. CI is omitted because it
disables Metro file watching in this SDK.

These are local development-server checks. Sprite forwarding, authenticated
transport, browser rendering/control, WAN measurements, persistent app data and
iOS app builds remain unverified. The runtime report has separate local Metro,
local backend and Fast Refresh flags; Sprite and browser flags remain false.


### Dedicated-account runtime attempt: September 6, 2026 UTC

The user supplied the report for runtime
`experiment-41e30be0-0dd3-4706-809f-df03bfa59d7c`, started at
`2026-09-06T00:06:45.008Z`. Local services started in 1,031 ms and the owned
emulator booted in 20,871 ms. The combined install/launch/greeting phase failed
after 185,255 ms with `Android UI hierarchy unavailable`; the greeting was never
observed. This report alone does not distinguish an app loading failure from an
accessibility-dump failure. Native runtime, local Metro/backend, Fast Refresh,
Sprite and browser verification all remain false.

Source restoration succeeded, and emulator cleanup completed in 1,923 ms. The
private run directory retains `commands.jsonl` and an attempted `failure.png`.
The copied diagnostics were subsequently reviewed; findings and the correction
are below. Future
reports separate APK install, local forwards, launch, and greeting observation,
and clear a stale hierarchy error after a successful hierarchy read.


### Diagnosed startup blocker and correction

The user copied the private report, command log and screenshot to
`/private/tmp/switchyard-runtime-failure`. Review established:

- APK installation returned `Success`, both device forwards succeeded, and
  Android launched the fixture's `.MainActivity` with `Status: ok`.
- Metro built the 688-module Android bundle in 7,311 ms and received a
  React Native JavaScript warning from the running fixture.
- The first hierarchy poll returned `null root node`; **53 subsequent hierarchy
  reads succeeded**. The old timeout incorrectly retained that initial error.
- The runner tapped onboarding's **Continue**, then left Expo's developer menu
  open. The final screenshot shows that menu connected to `127.0.0.1:51472`.
  The app greeting was covered and was not verified.

SDK 54's installed `expo-dev-menu` source confirms that `FinishOnboarding`
changes onboarding state without closing the menu. The corrected startup path
recognizes the fixture's Expo header, completes onboarding, then taps the
menu's **Close** control. It uses fresh UI bounds, records the startup actions
and pre-action XML/PNGs, and permits at most three such taps while waiting for
the initial greeting. Later checks, including Fast Refresh, cannot dismiss
arbitrary Continue/Close controls or invoke startup actions. Generic controls,
other packages and unknown Expo headers are rejected by the selector.

A regression test covers onboarding → menu → greeting and the negative selector
cases. The corrected dedicated-account run subsequently passed (recorded below); the
earlier failed report remains unchanged. No APK rebuild is needed for this runner fix.


### Dedicated-account runtime success: September 6, 2026 UTC

The user supplied the successful report for
`experiment-94aabf26-f376-466d-9152-c02bca8049ce`, started at
`2026-09-06T00:21:33.519Z`, using the same pinned APK/build as above. All 13
phases passed. The runner completed onboarding and closed the developer menu,
then observed the greeting, counter tap and ASCII name entry, a nonce-bearing
local backend response, and the uncommitted greeting edit with name/counter
state preserved. Capture and scroll assertions passed. Source restoration and
owned emulator cleanup completed successfully.

| Observation | Elapsed time |
| --- | --- |
| Owned emulator boot | 28,016 ms |
| APK install | 2,279 ms |
| App launch | 4,963 ms |
| Greeting observation, including onboarding | 27,464 ms |
| Tap and text check | 13,670 ms |
| Local backend check | 5,094 ms |
| Fast Refresh check | 6,408 ms |
| Capture and scroll | 22,207 ms |
| Emulator cleanup | 2,400 ms |

These are experiment phase durations, including polling and capture, **not**
input latency or pure HMR latency measurements. The supplied report verifies
native runtime, local Metro, local backend and Fast Refresh under `switchyard`.
The new capture file has not been independently decoded or visually reviewed.
Sprite Metro, browser viewing/control, WAN behavior and persistent device data
remain unverified. Runtime App digest:
`89db83ff574e009070c41764dff4e725eb8c21cf8fac93bd91bac2232b1367cb`.


## Private service transport milestone (before pairing integration)

An isolated runner loopback forward, credit-bounded TCP-over-WebSocket transport
and server gateway adapter have been added. Local tests passed for a
1,049,307-byte binary round trip with exact length and SHA-256, an HTTP bundle
response, nested HMR WebSocket upgrade/framing, rejection of missing credentials
/browser origins/wrong session paths, and immediate cancellation of an active
forward. A stalled destination remained within its 64 KiB receive window and
invalid acknowledgements failed closed.

Tests use a supplied authorization callback and independent Node TCP peers.
They do not establish production session authorization, actual Sprite forwarding
or Expo HMR over the relay. The adapter is not attached to `server/index.ts` or
used by `--run-hello`. The next integration must supply server-resolved named
services and live assignment/access signals; no arbitrary forwarding destination
may come from browser or agent input. Detailed limits and the observed Bun raw
TCP compatibility limitation are recorded in the runner README.

`server/native-forward-access.ts` now supplies a separately tested authorization
component using the real Switchyard database access model. Grants bind a browser
session verifier and user to a runner connection epoch, native session generation,
track/workspace identity, and server-provided `metro`/`backend` destinations.
Only token hashes are retained. Grants last at most 60 seconds and never outlive
the assignment lease. Project membership events revoke access immediately;
one-second polling also catches sign-out and assignment changes without events.
Tests cover revoked membership, closed tracks, archived/revised projects, runner
project removal, connection replacement, changed destinations, late connection
completion, idle expiry, bounded issuance and independent peer tracks.

This component remains unmounted. Its trusted assignment lookup must come from
the future runner/service manager, which must invalidate assignments when a
Sprite or managed service changes. There is no production pairing or token
delivery route, managed Metro reservation, automatic credential renewal, or
live Sprite connection yet. The default connector is the existing private
Sprites transport; the access tests supply destination streams instead.

## Hello World Switchyard workspace

Created through the signed-in Switchyard UI after the user renewed their GitHub
sign-in:

- App origin: `https://switchyard.demo.managoat.com`.
  `preview.switchyard.inevitable.fyi` is the separate web-preview domain.
- Private repository: `managoat/switchyard-expo-hello`.
- Project: `e96fc271-182f-44df-a097-55db90ed2932`.
- Track: `d792d4c2-26ac-4708-aef1-b1a2f21b44cd`, named
  **Native preview verification**.
- [Open the track](https://switchyard.demo.managoat.com/p/e96fc271-182f-44df-a097-55db90ed2932/t/d792d4c2-26ac-4708-aef1-b1a2f21b44cd).
- The branch picker showed `main` at `68fabcd`; the completed opening turn
  reported `/home/sprite/work/main` on branch `jhgaylor/main`.

The UI reports the track ready. This means the workspace was created, not that
native preview is ready. Metro and backend services have not been started there,
and the Mac APK has not yet been built from a snapshot exported by that track.

The expired GitHub token exposed a missing sign-out control. Local changes add
**Sign out** to the sidebar and **Sign in again** to the repository picker on a
401 from the user's GitHub token. The latter obtains a fresh OAuth attempt and
avoids incorrectly showing an empty repository list. Regression tests cover
the recovery action, server session revocation, and distinguishing GitHub 403
permission failures from expired credentials. These UI changes are not deployed.

## Paired Sprite/browser implementation — local verification

The opt-in Hello experiment is now wired through the app router and main
WebSocket server. It includes owner pairing, bounded assignment leases, private
managed Sprite installation/Metro/backend services, additive SQLite reservations
and recovery cleanup, runner loopback forwarding, scrcpy 4.1 live H.264/control,
and a separate browser canvas viewer with one-controller acquisition.
`native-forward-access.ts` remains a separate future registration component;
the current experiment manager performs its own assignment/access validation.

Validation on this checkout:

- **276 tests passed**, 1,707 assertions across 32 files; production TypeScript,
  SPA and server builds passed. Shell syntax and diff whitespace checks passed.
- The composed integration test used a real loopback forward, native gateway,
  Sprites tunnel and a local provider fixture to fetch Metro `/status`.
- Tests cover single-use pairing, origin/owner checks, creator sign-out,
  native-input mismatch, controller exclusivity/cancellation, keyframe delivery,
  late service creation, malformed/oversized claims and cleanup retry.
- Chrome decoded synthetic Annex-B H.264 at approximately **29–30 fps**. Tap,
  text entry and Back reached the local input fixture. This establishes browser
  compatibility with the implemented framing, not real-device or WAN success.
- A local `switchyard:native-preview-review` container image built successfully
  and its internal `/healthz` endpoint passed without host ports or data mounts.

No live Sprite Metro, Sprite backend, browser-to-emulator control or HMR result
has been established by these checks. The next run requires deploying the tested
app with the experiment flag and invoking `--preview-hello` under `switchyard`.
The runner intentionally does not mark browser verification from transmitted
frame counts. See the [pairing instructions](../runner/README.md#paired-android-hello-preview).

Gate 2 remains open until that deployed run proves the complete path and cleanup.
The full brief also still requires durable runner identity/registration, queues,
build reuse/invalidation for arbitrary workspaces and iOS parity.

## First deployed Android preview — September 6, 2026 UTC

Implementation `6f0b37f` passed CI and rolled out through image-pin commit
`07860ec`. Public `/healthz` returned `ok`; the deployed image matched the
implementation SHA. Session `12a21bd2-5563-47f4-b675-fbd894f2bd5d` paired with the
user-started dedicated Mac runner and reused the pinned, previously verified APK.

The initial dependency install could not resolve npm. The Hello Sprite's policy
allowed only `broker.inevitable.fyi`; that domain resolved while npm and GitHub
failed. With explicit user approval, added the exact `registry.npmjs.org` allow
rule, preserving the broker rule. The same install resumed and completed
(716 packages; about seven minutes including blocked retries). Metro and the
backend then started on private Sprite ports 30000 and 30001. No public Expo
tunnel or provider credential in the app was used.

Observed in Chrome through `switchyard.demo.managoat.com`:

- Real H.264 Android frames, including initial bundling and the Hello app.
  Metro logged a 7.1-second first Android bundle (688 modules).
- The runner reached Ready after seeing the greeting and Sprite backend reply.
  The browser independently showed **Hello from the Sprite backend!**.
- Browser control incremented the counter to **1**, entered **world Jake** in
  the app's name field, dismissed the keyboard with Back, and scrolled to
  **You reached the end.**
- A track conversation changed the greeting and added an animated dot without
  committing or restarting Metro/device. The browser showed the edit and
  approximately **28–31 decoded frames/second** while animating. This is observed
  frame throughput, not a latency percentile or a phone-browser result.
- A second conversation changed only GREETING to **Updated live**. The browser
  showed **Updated live, world Jake!**, counter **1**, and the existing backend
  response together, establishing Fast Refresh with state preserved.
- A second signed-in viewer decoded the stream but received **Another viewer
  controls this device** when trying to take control. An unauthenticated GET to
  the native session API returned **401**.
- Visual evidence retained locally at `/private/tmp/sy-native-live-20260906.png`.

Issues found during live testing:

- Damage-driven capture emits no frames on a still screen. The server's former
  15-second frame-age check incorrectly changed Ready to Connecting and blocked
  input. The correction uses the producer connection and runner lease for
  liveness after the first verified frame. A regression test advances time by
  20 seconds and proves static-screen readiness/control remain available.
- One repeated in-app backend request exceeded its eight-second deadline. The
  Mac loopback forward then returned HTTP 200 in 0.36 seconds and an in-app retry
  succeeded. The initial runner backend check also passed. Cause is unresolved;
  sustained backend reliability is not established.
- Metro warned that manifest asset resolution was aborted. The app bundle and
  HMR worked, but icon/font/asset and source-map coverage remains incomplete.
- A new viewer joining a completely static screen still needs verification:
  the current relay waits for a new keyframe and does not cache a full GOP.

The readiness correction passed **277 tests / 1,709 assertions / 32 files** and
the production build. Safari/phone compatibility, input latency percentiles,
reconnect and sleep behavior, live membership revocation, arbitrary track source
export/builds, and the remaining product/durability/iOS gates are not complete.

Cleanup was exercised using the browser **Stop** control. The three exact named
Sprite services returned absent, the SQLite reservation count became zero, and
no owned emulator or runner process remained in the Mac process listing. A
separate Sprite `git status --short` returned empty after the conversation
restored the test edits. The existing web preview remained in its original
Stopped/unconfigured state throughout this run.

The original deployed UI labeled the intentional Stop as `Failed: Runner
disconnected` despite successful resource cleanup. The follow-up fixes preserve
Stopped when the server closes its runner socket and send an explicit final
session result, allowing the runner to distinguish a normal Stop from transport
failure. The regression asserts Stopped, no error, and the final result message.

Both follow-up corrections shipped in image
`sha-27d0a3a4df308a7d27423f72b5441c39927a79c6` (CI pin `c77b5fb`). CI passed and the
rollout/public health check passed. The post-fix device run has not yet been
repeated; the regression tests establish the corrected state transitions. The
first run's backend timeout and static-screen late-join behavior remain open.


## iOS implementation awaiting dedicated-account proof

Added the Hello arm64 simulator build, full-bundle digest verification, private
CoreSimulator/idb ownership, persistent H.264/HID bridge, and platform-aware
pairing/viewer controls. The server offers iOS only after an operator pins a
successful build's artifact digest in `NATIVE_HELLO_IOS_SHA256`. An Android
artifact or pairing request cannot consume an iOS assignment.

Focused tests cover bundle tampering and executable permissions, runtime report
validation, baseline/high-profile SPS crop dimensions, fragmented pipe framing,
key/config packets, bounded accessibility coordinates and platform-bound pairing.
The full checkout suite passed 293 tests with one unrelated browser test skipped;
a subsequently added iOS runtime artifact test also passed. Typecheck and the
production build passed. These checks do not prove the real simulator app,
idb streaming, Sprite iOS bundling, input, Fast Refresh or browser decoding.
The dedicated account's Xcode build report and subsequent paired live run are
still required. See the [iOS commands](../runner/README.md#ios-hello-build-and-paired-preview).

The first dedicated iOS build (`bd436c09-6758-4aaa-ba74-86d8d170e4a9`)
completed npm installation, Expo prebuild and CocoaPods, then Xcode exited 70
before compilation: no eligible generic simulator destination, with an
“iOS 18.5 is not installed” message. No artifact was produced. Host inspection
found the 18.5 simulator SDK and an available 18.6 runtime. A disposable Xcode
project under `jake` accepted the same SDK/destination/architecture flags in a
clean environment, so the SDK/runtime version difference alone does not explain
the dedicated-account failure. No runtime mapping or installed platform was
changed. `provision-account.sh switchyard --check-ios-build <build UUID>` now
collects the dedicated account's first-launch status, SDKs, runtimes, runtime
mapping, device counts and the retained Hello workspace's destinations/settings.
It preserves `ios-diagnostic.json` alongside the failed report without compiling
or booting a device. The account-specific diagnostic is pending.


The dedicated-account diagnostic returned a successful first-launch check, the
18.5 SDK, available 18.6 runtime, and 11 available simulators, but still no
eligible Hello workspace destinations. A disposable copy of the exact fixture
including Expo prebuild and CocoaPods accepted simulator destinations under
`jake`, including through the runner's clean environment and subprocess wrapper.
Xcode's installer reported 18.6 was already downloaded; no download occurred.
The precise account-specific cause remains unconfirmed.

The candidate repair explicitly selects installed runtime build 22G86 for the
18.5 SDK only during the dedicated build, verifies destination eligibility,
then restores the previous account override/default. The real helper accepted
the disposable Hello workspace and restored the original mapping under `jake`.
Unit tests cover selection, existing overrides, cancellation/failure restoration
and missing runtimes. Typecheck passed. The same `--build-ios-hello` command now
uses this repair; its dedicated-account result is pending, and no simulator app
or live iOS preview has yet been verified.


The dedicated-account retry succeeded in build
`8bd7bc9e-f5e7-4822-a014-2c0a6aeb730b`. Destination verification passed after
selecting runtime 22G86; Xcode compilation took 162.3 seconds. The verified
arm64 simulator artifact is `SwitchyardHello.app`, 78,597,940 bytes across 196
files, bundle digest
`375169f807696ad02ea5d82f1456b94142378e9f306eb5555bab55afe9abab2f`.
Source and lockfile digests match the previously pinned Hello fixture. The
report completed without error, including the runtime-mapping cleanup. This
establishes the dedicated account's native iOS build only. Simulator launch,
Sprite Metro/backend, browser video/input and iOS Fast Refresh remain pending.


The first paired iOS run (`512857a9-d8b1-40a2-bffe-362e5d59e3b6`)
validated the build and reached Sprite service forwarding, then failed before
simulator boot because 127.0.0.1:41001 was occupied by a separate `sprite` process
under `jake`. The runner report recorded complete cleanup and zero video frames.
That listener was left running. The follow-up reserves free local ports before
claiming the session and passes them through the validated pairing assignment to
Metro/backend configuration. Tests exercise bind conflicts without stopping the
occupant, inactive-listener rejection, activation, assignment cancellation,
large binary traffic, HTTP and HMR upgrades, and port validation before consuming
the pairing code. Dedicated iOS runtime/browser verification remains pending.


The next paired iOS run (`9aca96a0-bcb9-458e-bd2a-26017ba6d948`)
passed forwarding, booted the owned simulator and streamed its screen to the
Chrome viewer at approximately 28 fps. The visible screen showed iOS's
“Open in ‘Switchyard Hello’?” development-client confirmation; the startup
helper did not recognize that dialog, so greeting verification timed out.
The helper now selects Open only when the exact Hello confirmation title and
Cancel action are present. Regression tests reject unrelated app prompts and
incomplete dialogs. This confirms browser video, but app launch from Sprite,
backend calls, browser input and iOS Fast Refresh still need the retry.


The follow-up session (`09adbfad-1c13-4a91-9526-f1085f64d09d`;
local experiment `f2459a5e-33ee-4c89-89ef-39df9c1b8514`) again streamed the
confirmation at approximately 25–29 fps. The user supplied its retained
accessibility hierarchy: the title matched, but Open's center was
(264.33333333333337, 468.6666666666667). The adapter forwarded those decimal
strings to idb's integer-coordinate tap CLI. It now rounds accessibility points
at that CLI boundary and rejects invalid coordinates. A regression test using
the supplied geometry failed with the original command arguments and passes
with `ui tap 264 469`; 23 focused runner/video tests pass. Dedicated-account
launch and subsequent app interaction still require another live run.


The user supplied report `67a92738-fb98-44b3-800a-08499e56475e` for session
`52a3a516-c9a5-4743-8c2c-fcbd3ee0ddde`: the five-minute viewer-idle limit ended
it during simulator boot, before capture or app verification; local cleanup
completed. The next session (`4d1c6276-9fa2-4025-b554-1857be508d42`) showed a
Sprite HTTP 500 during cleanup. Read-only checks subsequently found all three
owned services absent and the native cleanup journal empty. The viewer retained
the temporary cleanup error, obscuring the original cause. Cleanup errors are
now tracked separately: the original reason remains visible, and the cleanup
warning disappears when retry succeeds. Eleven native-session tests and the
typecheck pass. The latest local runner report is still needed to establish
why that session originally ended; neither attempt establishes iOS app readiness.


The user supplied the remaining report for local run
`3713389c-ad6a-4153-ba88-02518192b2b4`, session
`4d1c6276-9fa2-4025-b554-1857be508d42`. It ended while waiting for private
Sprite services with Bun's unexpected socket-closure error, before forwarding,
simulator boot or capture. Local cleanup completed. The exact cloud request is
not identified by this report. After deployment of the error-preservation fix
(`6fe9326`, workflow `34011397427`, rollout and public health successful),
provider GETs responded normally, a read-only Sprite exec returned HTTP 200 and
confirmed App.tsx/server.mjs/Expo CLI in the Hello worktree, and the cleanup
journal remained empty. These checks support retrying, but do not establish
that the transport failure cannot recur.


Session `0a9b0148-af75-4952-8ad5-a98b89504e54` (local report
`cc9835d1-cfd5-4eb7-b73d-8102991f670f`) failed before forwarding with
“Workspace command failed.” Inspection found two managed services from the
first iOS session `512857a9-d8b1-40a2-bffe-362e5d59e3b6` running again, with
provider start timestamps 04:20:21Z. Its backend occupied Sprite port 30001;
30000 was free. The cause of those old definitions returning is unconfirmed.
After validating their exact experiment names and Hello worktree, only that
session's backend/install services and temporary preload/status files were
removed. A subsequent service listing was empty and fresh bind probes confirmed
both 30000 and 30001 free. The generic workspace error was consistent with the
port probe's silent nonzero exit. A new dedicated-account run remains necessary.


The next run reached the ten-directory retention limit before claiming its
pairing. `--archive-runtime` now moves completed, cleaned-up runtime evidence
intact into a private archive batch and records the path mapping. It uses the
runtime lock and skips builds, incomplete cleanup, foreign/malformed reports
and links. The original ten-run acquisition limit remains. Twenty focused
archive/runner tests pass, including byte preservation, freeing quota, active
lock refusal and leaving unconfirmed evidence untouched. Dedicated-account
archiving and the subsequent iOS preview still need the user's sudo invocation.
