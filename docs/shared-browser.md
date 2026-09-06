# Shared browser

Switchyard owns the browser session. There is one shared profile per project
machine, used by every authorized participant and agent across its tracks.
Actors have control leases; they do not have personal browser profiles.
Machine-account logins are ordinary state in that shared profile. Opening or
closing a chat does not create or destroy the profile, and closing a track does
not stop the browser.

## Runtime and setup

Enable `SHARED_BROWSER=1` on the Switchyard server, alongside `FOUNTAIN_API_KEY`
and `SPRITES_TOKEN`. Open a track and use **Shared browser → Open browser**.
The first open installs pinned `playwright-core@1.63.0` and its Chromium build
on the Sprite, then registers the private `switchyard-browser` service.
The machine must have Node, npm, and Chromium's Linux system libraries.
Provision the system libraries in the machine image/setup using Playwright's
documented `install-deps chromium` command, with the machine's normal package
installation privileges. Chromium runs with its sandbox enabled.

The service listens only on loopback port 40000, outside the web and native
preview port ranges. It has no Sprite public HTTP port. Switchyard reaches it
over the existing authenticated Sprites TCP tunnel and supplies a service
credential from encrypted server storage. Remote pages cannot call the private
RPC: it requires that credential and refuses browser Origin headers. Browser
traffic, cookies, and executable page content do not run in Switchyard's origin.

The runtime and profile are under `/home/sprite/.switchyard` (the repository's
`STATE_DIR`), outside track worktrees. Profile storage uses a session ID and an
internal profile generation; no path derives from a participant's identity.
There is deliberately no profile picker. A future profile catalog can use
these IDs without changing the actor/control model.

**Stop browser** saves state and closes Chromium, retaining the profile.
Opening it again reuses the profile and saved tab URLs. The service periodically
saves portable state as well as using Chromium's persistent data directory.
Machine parking can suspend the process; replacement of the disk requires a
checkpoint restore. A new process invalidates every previous control lease.
Active viewers/operations refresh an expiring Sprite activity task; a hidden
chat does not keep a machine awake indefinitely.

Project rebuild/delete stops the service before removing the machine. Browser
checkpoints stay in Switchyard's database, independent of the Sprite disk.
They are not automatic backups of everything since the last explicit checkpoint.

## Chat and agent behavior

The browser card sits inside the transcript, after the current conversation.
It attaches to the session, with a tab picker and an expanded dialog. Hiding the
card or leaving the track releases human control. Input supports click, scroll,
text/paste, and keys; the remote viewport is 1280 × 800. Explicit text, Tab and
Enter controls work without sending the chat's own focus navigation remotely.

There is one controller for the entire profile, not one per tab. This prevents
agents on separate tracks from racing shared login state. A human may take over
from an agent; a second human waits until the first releases or their 30-second
lease expires. Viewing and inspection remain available while someone else
controls. Input includes a browser revision so pre-restore commands fail.
An operation already dispatched to a website can finish before a takeover;
handoff does not cancel or undo an external action.

Each delivered prompt gets a temporary, track-scoped browser helper outside
the checkout. It supports start/status, acquire/release, tabs/navigation,
accessibility inspection, JPEG screenshots, input, and checkpoint creation.
Screenshot bytes can be written directly to an agent-selected local image path.
Credentials are never included in the transcript. Membership, prompt delivery,
conversation identity and machine identity are checked before operations;
removing and reinviting someone does not resurrect their old helper.

This is a shared session: a track invite grants access to its machine's shared
browser state when this feature is enabled. Track worktrees and transcripts
still retain their existing access boundaries.

## Checkpoints and restore

Checkpoints contain a versioned Chromium storage snapshot (cookies,
localStorage and IndexedDB), tab URLs, and per-tab sessionStorage. The snapshot
is encrypted with Switchyard's existing AES-GCM cipher before SQLite storage.
API responses contain checkpoint metadata only. The current limits are 20 tabs,
20 checkpoints per session and 16 MB per checkpoint response.

Any participant controlling the shared browser can save a checkpoint. An owner
can restore one into the current project or paste its ID into another project
they own. This copies saved state into that project's session; it does not
move the original session or merge two active profiles. Owners can delete
checkpoints from the source project's card.

Restore closes the destination's tabs and stages a new browser profile. Only
after storage is applied and tabs reopened does it switch the saved profile
reference, invalidate control and retire the old profile. On a restore error
it attempts to reopen the previous profile. Tab addresses are opened as fresh
HTTP navigations; clicks and form submissions are never replayed.

This is a portable storage checkpoint, not a VM/memory snapshot. It cannot
undo bookings, purchases, messages or other website actions, preserve arbitrary
JavaScript/DOM state or browser history, or guarantee that a website accepts a
restored login. It does not capture downloads, extensions, service-worker
caches, OPFS or hardware-backed credentials. Website scripts can continue
changing storage while the snapshot is collected; it is not a transactional
snapshot of the website's backend.

## Verification and remaining work

Local verification on 2026-09-05 used macOS Chrome with temporary profiles and
a disposable local website. It proved shared control and human takeover,
mouse/text/key input, screenshot rendering, session-cookie/localStorage
persistence after worker restart, and cookie/localStorage/sessionStorage restore
into a separate browser directory. Server tests cover shared identity across
tracks, access/origin checks, concurrent starts, restart/profile reuse,
credential exclusion, encrypted checkpoint persistence across a database reopen,
cross-project owner checks, machine replacement and helper revocation.

The production build and existing Switchyard test suite passed during the
implementation. The local UI proof exercised opening a tab, taking control,
typing and saving a form, expanding the card, and saving/restoring a checkpoint
through the card. Restore released control and the browser console stayed clear.

The initial viewer uses demand-driven JPEG polling, not a continuous video
stream. It is suitable for proving the session and handoff workflow; it has no
measured production frame-rate or latency guarantee. Drag gestures, file
uploads/downloads, explicit JavaScript-dialog handling (currently dismissed),
and higher-quality streaming remain follow-up work. The card is a live session
attachment, not a set of immutable browser artifacts attached to individual
historical turns.

Live Sprite provisioning, Linux Chromium sandbox/system dependencies, tunnel
latency, parking/recovery, and real external-site login compatibility have not
been verified by this local proof. No deployment or real account/booking action
was performed.

Run the real-browser test:

```sh
cd apps/switchyard
SWITCHYARD_BROWSER_TEST_EXECUTABLE='/path/to/chromium' bun test runner/browser-worker.test.ts
```

Run the interactive UI proof (real UI/router/worker, local transport in place
of Sprites):

```sh
SWITCHYARD_BROWSER_TEST_EXECUTABLE='/path/to/chromium' bun scripts/browser-live-proof.ts
```

Open `http://127.0.0.1:5199`, then visit the fixture URL shown there inside the
shared browser card. On macOS, the executable can be
`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`. This launches
a separate temporary profile and does not attach to personal Chrome state.

Reference: [Playwright persistent contexts](https://playwright.dev/docs/api/class-browsertype#browser-type-launch-persistent-context),
[storage state](https://playwright.dev/docs/api/class-browsercontext#browser-context-storage-state),
[system dependencies](https://playwright.dev/docs/browsers#install-system-dependencies).
