# Native runner experiments

This companion implements isolated native tool experiments plus Android and iOS
Hello preview paths for gates 1–2 of the [brief](../docs/native-preview-runners-brief.md).
Local Android runtime and Fast Refresh passed on the dedicated account. The
paired Sprite/browser path has also been exercised live in Chrome, including
input, Sprite backend calls, state-preserving Fast Refresh and targeted cleanup. Remaining gates and observed results are
in [verification](../docs/native-preview-runners-verification.md).

From `apps/switchyard`:

```sh
bun run runner:doctor
bun run runner --help
bun run runner:test
```

`doctor` prints JSON and returns 1 if either platform lacks its checked
prerequisites. It reads host architecture, CPU/RAM, OS, SDK/CLI availability,
installed Android system images and AVD profiles, Xcode, installed iOS runtimes and device types. It does not
install anything, accept licenses, pair, boot, start ADB, or build an app.
`livePreviewVerified` is always false. Emulator version, acceleration and AVD-list probes run sequentially, each with
a 60-second deadline; other probes retain 15-second deadlines. Reports include
elapsed time and deadline for each probe. A successful inventory does not establish
build, capture, input, codec or browser compatibility. idb CLI availability is
checked with `--help` because its CLI has no portable `--version`; companion build
information is reported separately. Record the installed fb-idb package version
with the live results when provisioning its Python environment.

The tool searches `ANDROID_HOME`, `ANDROID_SDK_ROOT`, the standard macOS SDK
location, and `PATH`. It also discovers Homebrew OpenJDK 21 and idb executables
in `~/.local/bin`, and adds them to subprocess environments without editing
shell profiles or the system Java installation. SDK command-line tools must
live under the SDK root used for images; install `cmdline-tools;latest` into
that root, because Homebrew's separate `avdmanager` resolves its own SDK. Add versioned SDK command-line tools to `PATH` if they are
not installed under `cmdline-tools/latest`. Run under the intended dedicated
account. The user confirmed this checkout's Mac as the runner host. The dedicated `switchyard` account is provisioned and now passes Android/iOS
diagnostics. The earlier live capture/input experiments ran under `jake`; they
have now been followed by a successful Android Hello runtime, input, local
Metro/backend, Fast Refresh and capture/scroll check under `switchyard`. iOS
runtime work under that account remains pending.
CoreSimulator inventory may fail inside a filesystem/process sandbox; that is
an inaccessible inventory, not evidence that no simulator runtime is installed.

## Run the first capture experiment

First confirm the Mac/account and provision the selected SDK/runtime and capture
tools. These commands create and boot a fresh owned device, open its Settings app, swipe, tap and enter text, save before/swipe/after
PNGs and a bounded MP4 recording, then
stop and delete that experiment's device. They do not use a personal AVD or an
existing simulator. They are workstation setup experiments; they are not normal
preview operations exposed to a Switchyard user or agent.

Choose installed values from the inventory. The installed package versions are recorded in [toolchain-macos.json](toolchain-macos.json). The Android values below match this Mac. Set `scrcpyVersion` to the exact installed
version; a mismatch fails before creating a device. No binaries are downloaded.

```json
{
  "stateDirectory": "/private/tmp/sy-native",
  "platform": "android",
  "systemImage": "system-images;android-35;google_apis;arm64-v8a",
  "deviceType": "pixel_7",
  "emulatorPort": 5580,
  "scrcpyVersion": "4.1"
}
```

An iOS example using the runtime observed on the checkout host:

```json
{
  "stateDirectory": "/private/tmp/sy-native",
  "platform": "ios",
  "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-18-6",
  "deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
}
```

Save a config outside the repository, then run:

```sh
bun run runner experiment /absolute/path/experiment.json
```

State must use an absolute real path, without symlink ancestors, owned by the
current account with mode 0700. A missing state directory is created privately.
iOS allocates its Unix socket in a separate, private `sy-idb-*` temporary directory
to stay within the socket path limit. Its exact path is recorded in `device.json`
and removed after the owned companion exits. The simulator set stays in the
experiment directory.

Android creates an AVD definition and writable state under the experiment's
private `ANDROID_USER_HOME` / `ANDROID_AVD_HOME`. It checks for an occupied
emulator serial before boot and verifies the new AVD name before input. It runs
the emulator in the foreground without a window, with four cores, 4 GiB RAM and hardware GLES (Vulkan disabled), and uses only serial-scoped
ADB operations. It never stops the shared ADB server.

iOS uses `simctl --set` with a private simulator set and explicit created UDID.
Its idb companion binds a private Unix socket. The CLI connects directly to that
socket and disables pruning of unrelated idb registry entries. No control TCP
listener is intentionally exposed. This private-set/socket path was exercised with Xcode 16.4, iOS 18.6 and the
pinned idb versions; see the verification record for the tested controls.

Commands use argument arrays without a host shell. They have output and time
limits; cancellation terminates their process groups, with SIGKILL fallback.
Capture/input runs concurrently so capture does not block commands. Device data
is disposable here; persistent track data and assignment leases belong to later
session implementation.

## Evidence and cleanup

Each run retains `doctor.json`, `report.json`, and any successful `before.png`,
`swipe.png`, `tap.png` (Android), `after.png`, `capture.mp4` and bounded per-command diagnostics in
`commands.jsonl`. iOS also records its owned set and UDID in
`device.json`. Android retains fresh UI hierarchies and display dimensions; failures
after the first screenshot also attempt to retain `failure.png`. The report distinguishes command acceptance and file creation
from visual correctness. Review the images and video; successful exit codes do
not prove the intended gesture took effect. Fixed experiment coordinates are
not the future normalized browser input implementation.

One experiment may run per state directory. Up to ten experiment directories
are retained; further runs refuse until old evidence is reviewed and removed.
The requested recording window is twenty seconds; actual media duration is
measured separately because capture startup and stream cadence vary. Commands
have wall-clock timeouts, output has explicit byte budgets,
and results reject video over 64 MiB or screenshots over 16 MiB. These checks are
not an OS disk quota. Production artifacts will need a separate eviction policy.

On failure, ordinary cleanup runs without the cancelled operation's signal. A
cleanup failure retains `experiment.lock` and the manifest. After a process
crash, inspect those files and clean only the indicated AVD/private simulator
set before removing the lock. Never guess an unrelated PID/serial, use
`simctl ... all`, or clear personal simulator data. Automatic crash recovery and
lease reconciliation are not implemented by this experiment tool.

The Android capture command follows [scrcpy's recording options](https://github.com/Genymobile/scrcpy/blob/v4.1/doc/recording.md).
iOS capture uses [idb's video command](https://github.com/facebook/idb/blob/main/idb/cli/commands/video.py)
and [private simulator set / Unix socket options](https://github.com/facebook/idb/blob/main/idb_companion/main.m).
This records native video files. It does not prove the scrcpy server/Tango wire
integration, WebCodecs or software decoding, WSS relay, WAN latency, mobile
browser behavior, Expo development builds, private Metro/HMR, or app backends.


## Installed on this Mac

Homebrew installed OpenJDK 21, scrcpy 4.1, CocoaPods 1.17.0 and Android command-line
tools. SDK Manager installed platform-tools, emulator 37.1.11, API 36/build-tools
36.0.0, and the API 35 Google APIs ARM64 image (revision 9) into
`~/Library/Android/sdk` (about 5.5 GiB). Standard SDK package licenses were
accepted as part of installation. Homebrew also updated required dependencies,
including FFmpeg to 9.0.1.

The idb Python client (`fb-idb==1.5.2`) is installed with `uv tool`, using Python
3.12. Current Meta Homebrew companion 1.5.2 requires Xcode 26; this Mac has Xcode
16.4. The official universal companion 1.1.8 archive was instead verified against
Meta's [historical formula checksum](https://github.com/facebook/homebrew-fb/blob/c038679/idb-companion.rb)
and installed in `~/.local/share/switchyard/tools/idb-companion/1.1.8`, with
`~/.local/bin/idb_companion` pointing to its executable. Its framework tree is
preserved. No Xcode upgrade, system Java symlink or shell profile edit was made.

The client and companion versions deliberately differ: only the operations
actually exercised in the verification record are established to interoperate.
Keep both pinned for this experiment; this is not a promise that new idb APIs
work with the older companion.


## Set up the dedicated account

The local `switchyard` account was created by the user (UID 502, standard user).
The user ran provisioning: `/Users/switchyard` was created and the tool
installation completed. The initial check hit 15-second emulator timeouts; the
updated recheck now passes both platforms under `switchyard`. For reference,
the first-install command from the Demos checkout root is:

```sh
sudo /bin/bash apps/switchyard/runner/scripts/provision-account.sh switchyard
```

Review [the setup script](scripts/provision-account.sh) first. It creates the
account home if needed, stages the installed Android SDK, idb companion, Bun, uv
and runner source, then copies them into the new account while running as that
standard user. It installs `fb-idb==1.5.2` in that user's isolated Python
environment and writes a private doctor report. It uses the shared Homebrew
Java, Node, scrcpy and CocoaPods installations. Allow roughly 12 GiB of extra
free disk space during SDK staging/copying; the temporary stage is removed.

The command prompts locally for your **administrator** password through sudo.
It never requires sending the account password to an agent. It copies no shell
profiles, GitHub/SSH credentials, keychains or personal SDK device data. No sudo
rule, administrator membership, login service or runner pairing is installed.
The companion currently remains the diagnostic/experiment executable.

This is first-install setup: an existing runner installation is retained and
causes a refusal. If a check fails after copying, inspect its private
`~/.local/share/switchyard/doctor.json` rather than deleting the installation.
CoreSimulator may require first-login initialization for the new account.

Run subsequent diagnostics **as the runner account** with:

```sh
~/.local/bin/switchyard-runner doctor
```

Refresh just the diagnostic module and rerun checks without copying SDKs or
installing packages:

```sh
sudo /bin/bash apps/switchyard/runner/scripts/provision-account.sh switchyard --check
```

This prints blocker lists plus emulator results/timings and retains the full
report under the runner account. It can take up to three minutes if all emulator
probes time out; a timeout still fails readiness. The new diagnostic passed under both `jake` and `switchyard`. The original timeout
cause remains unconfirmed.

To read only the
failures from the retained report after an older setup run:

```sh
sudo -u switchyard /Users/switchyard/.local/bin/bun -e '
  const d = await Bun.file("/Users/switchyard/.local/share/switchyard/doctor.json").json();
  console.log(JSON.stringify({android: d.android.blockers, ios: d.ios.blockers}, null, 2));
'
```

This read requires local sudo authentication; the agent running as `jake` cannot
read the private report. The existing live experiments were run as `jake`, so
they do not establish readiness under the new account.


## Build the Hello World Android artifact

The fixture is [managoat/switchyard-expo-hello](https://github.com/managoat/switchyard-expo-hello).
This build-only experiment creates a debug development APK; it does not start a
device or Metro, install an app, or provide a browser preview.

A source snapshot has been prepared at `/private/tmp/switchyard-hello-source.json`
from the fixture checkout. To refresh it after edits, from the Demos root:

```sh
bun apps/switchyard/runner/index.ts snapshot /private/tmp/switchyard-expo-hello /private/tmp/switchyard-hello-source.json
```

Then run the build under the provisioned standard account:

```sh
sudo /bin/bash apps/switchyard/runner/scripts/provision-account.sh switchyard --build-hello
```

The helper stages only the current runner code and source snapshot, drops to the
standard account with an empty environment, and runs the build there. It does not
replace the installed adapters or copy personal credentials. Its temporary staging
area is removed after the build. Account-owned source, logs and the artifact remain
under `~/.local/share/switchyard/builds/experiment-<id>` for review.

The pipeline validates the snapshot and fixture identity, runs Android inventory,
extracts into a fresh private worktree, installs dependencies with `npm ci`, runs
`expo prebuild --platform android --no-install`, then Gradle `:app:assembleDebug`
for ARM64 only. Gradle runs without a persistent daemon, with two workers and a
3 GiB heap. Its per-build caches and temporary files are isolated. Dependency and
build scripts execute as the dedicated account; this is not an OS sandbox.
Gradle may download required SDK/NDK/CMake components using the installed licenses.

The total deadline is 45 minutes, with 10 minutes for dependency installation,
five for prebuild, and 30 for Gradle, all subject to the total deadline. Output
per command is capped at 8 MiB and an APK at 512 MiB. Ten build experiments may
be retained; manual review/removal is needed after that. This is a count limit,
not a disk quota or production cache eviction policy. Failed builds retain logs.

Before accepting an artifact, the runner checks its package ID with `aapt2`, checks
for the ARM64 ABI and records its SHA-256, source digest and lockfile digest.
Successful compilation alone does not establish native runtime readiness. The
first live native build passed under `switchyard`; its artifact identity and
timings are recorded in [verification](../docs/native-preview-runners-verification.md).

### Source export limits

The first format is a bounded JSON manifest with base64 file contents: 5,000 files,
8 MiB per file and 32 MiB total content. Paths, permissions, sizes and content hashes
are validated before extraction into a new directory. Export selects tracked and
eligible untracked files from the entire repository root, preserves executable
bits, and omits deleted files. No commit or push is required. Two full scans must
agree; observed churn retries up to three times. This detects observed changes,
not an atomic filesystem snapshot.

Git internals, dependency/cache/build directories and known private configuration
paths are excluded. All symlinks and special files are rejected. Ignored inputs,
private registries, injected build secrets and projects that require excluded
checked-in build output are unsupported in this experiment; they need explicit
project configuration in the production path. Manifest validation rejects path
traversal, conflicting paths, Mac case collisions and altered content. Native
prebuild modifies only the extracted stage.

This local export/build path is not yet integrated with Sprite source transfer,
track configuration, native fingerprint invalidation or a reusable build cache.


## Run the built Hello app locally

Prepare `/private/tmp/switchyard-hello-runtime.json` as the provisioning account,
using an explicit successful build and its APK digest (no newest-build selection):

```json
{
  "expectedAccount": "switchyard",
  "buildDirectory": "/Users/switchyard/.local/share/switchyard/builds/experiment-52e8255f-b89c-4596-846d-1aa6d6002041",
  "artifactSha256": "6bf899d7e847633cb70f02aa37b6c5ba8db32d07ff0e8cfb7bb5a168d92afe82"
}
```

Then, from the Demos root:

```sh
sudo /bin/bash apps/switchyard/runner/scripts/provision-account.sh switchyard --run-hello
```

This reuses the APK and installed dependencies. It verifies the artifact hash
and successful build report, starts local Metro and a small local backend,
creates a fresh Pixel 7 API 35 ARM64 emulator on console port 5580, and installs
and launches the fixture using explicit serial-scoped ADB commands. Occupied
emulator serials are refused. ADB reverses only the owned device's two allocated
ports. Metro and the backend bind loopback; the existing ADB server is shared
and never globally stopped. It pins scrcpy 4.1 and has a 15-minute total deadline.

During initial launch, the runner identifies the SDK 54 fixture's Expo
onboarding/menu, taps Continue and then Close using current UI bounds, and
retains each startup action with XML and screenshot evidence. These bounded
startup actions are disabled for the later input and Fast Refresh checks.

The run checks actual UI text after a counter tap, ASCII name entry and a backend
request. It includes the counter value in the staged fixture's accessibility
label so React Native's grouped button exposes its state to the UI hierarchy.
The report records this runtime `App.tsx` digest separately from the build
snapshot. It then changes the greeting in that staged `App.tsx` and waits
for Fast Refresh with the counter and name preserved, without issuing a reload.
It records a short native video while scrolling and saves UI hierarchies and
PNGs. A passing assertion establishes that observed UI transition, not browser
compatibility or human visual review of the recording. The original source is
restored during cleanup; if an external edit conflicts, it retains the original
and both locks for manual recovery instead of overwriting that edit.

Results live in `~/.local/share/switchyard/runtime/experiment-<id>`. Temporary
services and the owned emulator stop after completion or failure. The staged
source and APK remain in the build directory. A crash retains `runtime.lock` in
the build and `experiment.lock` in runtime state; inspect their referenced
evidence before targeted recovery. Ten runtime experiments may be retained.

This is a local runtime preflight. Metro and its test backend run on the Mac.
It does not yet test Sprite services, authorization, browser input/video,
persistent device state or the iOS app. No public tunnel or paired service is
installed by this command.


## Private forwarding transport

`loopback-forward.ts` and `tcp-tunnel.ts` implement an isolated transport for
Metro and named backend services. The runner binds only `127.0.0.1`, opens an
outbound WSS connection per local TCP connection, and sends a session credential
in the upgrade header. App traffic contains no runner/provider credential.
Plain WS is accepted only on literal loopback addresses for local tests.

The matching `server/native-forward-gateway.ts` requires an authorization
callback that supplies the destination stream and assignment-abort signal.
It rejects browser-origin upgrades, missing credentials and query-string
parameters before opening a destination. The callback must validate the actual
session, named channel and runner assignment and revoke the signal on access
loss. The gateway is mounted by the opt-in Hello experiment manager in
`server/native-experiment.ts`, which owns pairing, leases and named Sprite
services. It is used by `--preview-hello`; `--run-hello` remains local-only.

`server/native-forward-access.ts` implements the authorization callback against
Switchyard's track memberships and browser session verifiers. A trusted server
assignment lookup supplies the runner/project binding, connection epoch, session
generation and named service destinations; callers cannot choose a host or port.
Grant tokens are returned only to the server caller for future delivery on the
runner control connection, with only hashes retained. They expire within 60
seconds or sooner at assignment expiry. Membership events and one-second checks
revoke active channel signals; changes to the workspace or named services fence
the old grant. There is no automatic renewal yet. The assignment manager must
invalidate its records when a remote Sprite/service is replaced. This component
also remains unmounted pending managed services and runner pairing.

Framing preserves raw HTTP and nested WebSocket bytes, uses a 64 KiB window and
16 KiB frames per direction, and grants more credit only after destination write
callbacks. Source chunks are limited to 1 MiB; invalid frames, acknowledgements
and overruns close the channel. EOF waits for acknowledged writes, and full
closure waits for destination finish. Readiness and connection setup have
10-second deadlines; heartbeat requests run every 15 seconds with a missing-pong
cutoff at the next interval. Each forward admits 16 connections; the gateway
admits 64. Cancellation closes listeners and active connections. Video and
interactive controls use separate channels.

Local integration tests use separate Node TCP peers around the Bun transport,
covering a >1 MiB binary exchange, HTTP, nested HMR WebSocket framing, credential
rejection and cancellation. In-process Bun 1.3.11 raw TCP probes exposed
half-close/buffering problems; these tests do not establish reliability of Bun's
raw outbound `node:net` adapter. The experiment destination uses
the existing Sprites WebSocket-to-Duplex adapter. A composed test exercises it
against a local provider fixture; a live Sprite run is still pending. No WAN throughput or live Sprite HMR claim is made here.

## Paired Android Hello preview

Deploy the app with `NATIVE_PREVIEW_EXPERIMENT=1`. Only the project for
`managoat/switchyard-expo-hello` offers **Start Android preview**. Its owner starts
one experiment and receives a single-use pairing code valid for five minutes.
The app admits one experiment globally, reuses the verified APK below, and pins
native configuration, dependencies and image assets. Native changes require a
rebuild; this gate does not yet implement arbitrary repository builds.

Create `/private/tmp/switchyard-hello-preview.json` as the provisioning user,
mode 600, with these fields and a fresh code from the track:

```json
{
  "expectedAccount": "switchyard",
  "buildDirectory": "/Users/switchyard/.local/share/switchyard/builds/experiment-52e8255f-b89c-4596-846d-1aa6d6002041",
  "artifactSha256": "6bf899d7e847633cb70f02aa37b6c5ba8db32d07ff0e8cfb7bb5a168d92afe82",
  "serverUrl": "https://switchyard.demo.managoat.com",
  "pairingCode": "REPLACE_WITH_FRESH_CODE"
}
```

Then run from the Demos root:

```sh
sudo /bin/bash apps/switchyard/runner/scripts/provision-account.sh switchyard --preview-hello
```

This stages the current runner source, claims the experiment, waits for private
Sprite Metro/backend services, forwards them over authenticated outbound WSS to
two reserved free Mac loopback ports, boots an owned emulator, installs the pinned APK,
and starts scrcpy 4.1 H.264 capture. The runner checks the visible greeting and
backend response before allowing browser control. Open **Open device**, then
**Take control** to tap, swipe, scroll, type, use navigation keys, or capture a PNG.
The runner remains running for live browser verification; Ctrl+C or **Stop** ends
it. Reports and screenshots are retained in the account's runtime directory.
`browserVerified` remains false in the runner report: browser decoding and input
must be observed independently.

Pairing credentials never enter app traffic. The runner renews a 60-second lease,
with a 30-minute hard limit. Creator sign-out, lost access, closed tracks,
workspace replacement and disconnect revoke the experiment. There is one
controller and at most eight viewers. Cleanup stops only owned services/devices;
a SQLite reservation journal retains cloud cleanup work across server restarts.
Failed cleanup retries and blocks new experiments until it succeeds.

The first live run verified Sprite Metro bundles/HMR, a backend call, browser
decoding/control and Stop cleanup. Remaining checks include an intermittent
backend timeout, joining static video, manifest assets/source maps, latency
percentiles, Safari/phone support, and network/sleep recovery.
Durable runner registration, scheduling, arbitrary builds and iOS browser parity
remain later gates.

## iOS Hello build and paired preview

The iOS path is implemented but still requires live verification under the
`switchyard` account. Build from the same private Hello snapshot:

```sh
sudo /bin/bash \
  /Users/jake/dev/managoat/demos/apps/switchyard/runner/scripts/provision-account.sh \
  switchyard --build-ios-hello
```

The build stages source, runs npm/expo prebuild/CocoaPods, and invokes Xcode for
an unsigned arm64 iOS Simulator Debug app. It verifies the bundle identifier,
Mach-O platform and architecture, then hashes the entire `SwitchyardHello.app`
bundle including paths and executable permissions. The resulting report retains
the explicit build directory, digest and phase logs. Building does not establish
runtime, Metro or browser readiness.

After reviewing a successful build report, configure the Switchyard deployment's
`NATIVE_HELLO_IOS_SHA256` with its artifact digest. Only then does the Hello track
offer iOS in the platform selector. Start an iOS preview to obtain its one-use
pairing code. Prepare `/private/tmp/switchyard-hello-ios-preview.json` as the
provisioning account, mode 0600:

```json
{
  "platform": "ios",
  "expectedAccount": "switchyard",
  "buildDirectory": "/Users/switchyard/.local/share/switchyard/builds/experiment-<build UUID>",
  "artifactSha256": "<artifact digest from the successful iOS build report>",
  "serverUrl": "https://switchyard.demo.managoat.com",
  "pairingCode": "<fresh code from the iOS preview>"
}
```

Then run `provision-account.sh switchyard --preview-ios-hello` with sudo. This
creates an iPhone 16 on the installed iOS 18.6 runtime in a private simulator set,
installs only the pinned app, and forwards the same private Sprite Metro/backend
services used by Android. The simulator shares the Mac's loopback interface.
The runner verifies the greeting and backend response before enabling control.
Stop and assignment expiry terminate only its companion, bridge and simulator;
shared cloud service cleanup and access checks remain the same on both platforms.

Video uses the installed fb-idb 1.5.2 client with companion 1.1.8. A persistent
Python bridge retains H.264 access-unit boundaries and maps normalized browser
coordinates to simulator points. Its stdout frame parser and stdin input queue
are bounded. Capture requests 30 fps at half scale; actual stream dimensions
come from the SPS. Input supports touch, drag, scroll, Home, Enter, Backspace and
printable ASCII text. iOS has no Android Back control. Device rotation,
non-ASCII input, phone-browser compatibility and end-to-end latency are not
verified. idb does not supply capture PTS; the bridge timestamps arrivals.
The pinned encoder may reorder frames, so browser decoding and interactive
latency must be checked live before claiming parity.

If Xcode fails to select a destination, inspect the retained build with
`sudo /bin/bash runner/scripts/provision-account.sh switchyard --check-ios-build <build UUID>`.
This collects account-specific Xcode/runtime metadata and destinations into
`ios-diagnostic.json` in that build directory. It does not rerun dependencies,
compile, boot devices or change runtime mappings.

For the pinned Xcode 16.4 setup, iOS builds temporarily map the iOS 18.5 SDK to
installed iOS 18.6 runtime build 22G86 in the dedicated account. This selection
is recorded in the report, verified before compilation, and the prior mapping
is restored after success, failure or cancellation. It does not change the
simulator set or download another runtime. A toolchain upgrade requires updating
this explicit experiment pin. The dedicated-account retry is still required to
establish whether this resolves its destination rejection.


The runner reserves both loopback listeners before pairing and sends their port
numbers with its claim. Switchyard validates and echoes the pair, then advertises
those addresses to Metro and the app backend configuration. Incoming connections
are closed until pairing activates the forwards. Old runners retain the legacy
41000/41001 defaults; current runners coexist with other local forwards. Bind
errors now include the address and port. No native rebuild is required because
Metro supplies the app's JavaScript configuration.
