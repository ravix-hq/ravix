# Switchyard

**switchyard.demo.managoat.com** — parallel tracks on one cloud machine, on the
[Fountain](https://github.com/BinaryBourbon/fountain) API.

Sign in with GitHub, pick a repository, and switchyard builds it a machine with
the repository already cloned. Every piece of work you start on it is a
**track**: its own `git worktree`, its own branch, its own agent conversation.
Four of them can be in flight at once on one disk, and none of them touches
another's files.

It is [Conductor](https://conductor.build)'s shape — projects in a rail, threads
inside them, files and changes and checks on the right, a dock underneath — with
the local machine replaced by a sandbox somebody else is paying for. Where that
substitution costs a feature, the app says so in the place the feature would
have been rather than shipping a button that does nothing.

A React SPA over a Bun server. Client patterns are [paddock](../paddock)'s; the
identity model is paddock's too, per project rather than per person. What is new
here is a GitHub App, and the reason for it is below.

## Run it

Track previews: [feature brief](docs/track-previews-brief.md) and
[verification and deployment handoff](docs/track-previews-verification.md).

Three processes. The mock is a real enough Fountain **and** a real enough GitHub
to run the whole app offline, sign-in included:

```bash
bun install
bun run mock                        # a fake Fountain and GitHub on :8793
bun run server                      # the Switchyard server on :8081
bun run dev                         # the SPA on :5183
```

`bun run mock` prints the exact server command line, including a throwaway
GitHub App private key it generates for you.

Against the real thing, the server takes:

| | |
| --- | --- |
| `FOUNTAIN_URL` | defaults to `https://managoat.com` |
| `FOUNTAIN_API_KEY` | **required** — the account every machine is built on |
| `SWITCHYARD_SECRET` | encrypts stored GitHub tokens; generated into `DATA_DIR/secret` if unset |
| `PUBLIC_URL` | this server as GitHub reaches it; must match the App's callback |
| `GITHUB_APP_ID` `GITHUB_APP_SLUG` `GITHUB_CLIENT_ID` `GITHUB_CLIENT_SECRET` `GITHUB_PRIVATE_KEY` | all of them, or none of them |
| `SPRITES_TOKEN` | optional — enables terminal/run/vitals and the preview provider |
| `PREVIEW_DOMAIN` | optional — dedicated preview hostname suffix; absent means previews are unavailable |
| `PREVIEW_PORT` | private gateway listener, default `8082`; HTTPS ingress forwards here |
| `SHARED_BROWSER` | set to `1` to enable the persistent shared browser and agent helper |
| `DATA_DIR` `STATIC_DIR` `PORT` | as everywhere else in the suite |

Nothing needs registering on Fountain: the browser never talks to it, so there
is no OAuth client and no CORS origin.

## Experimental preview UI

The shared browser and Android/iOS preview controls are hidden by default,
including the direct `/native/:id` device viewer. Set
`VITE_EXPERIMENTAL_PREVIEWS=1` when running `bun run dev` or `bun run build`
to enable them. This is a build-time UI flag; changing it requires restarting
Vite or rebuilding the frontend. The corresponding server features must also
be configured. Regular track web previews remain available.

## Shared browser

With `SHARED_BROWSER=1`, each machine has one Switchyard-owned browser profile
shared by its tracks and participants. The chat card supports viewing, input,
human/agent handoff, and encrypted portable checkpoints that an owner can
restore into another project they own. It is separate from app previews and
does not require `PREVIEW_DOMAIN`. See [shared browser setup and verification](docs/shared-browser.md)
for runtime requirements, checkpoint semantics, and the local proof command.

## Track previews

Planned Android and iOS support is described in the
[native preview runner brief](docs/native-preview-runners-brief.md). The plan
uses a Mac runner and keeps the complete preview workflow in the browser.
Mac provisioning and native capture/input experiments are available through the [runner diagnostics and experiments](runner/README.md);
[verification status](docs/native-preview-runners-verification.md) records the
tested toolchains and remaining implementation gates. Native browser previews are not available yet.

Ask the conversation agent **“Set up a live preview for this track”**, or use
the **Set up live preview** starter on a repository track. It can inspect the
app, install its dependencies when needed, save the directory/command/readiness
settings, start the preview, and use status and logs to fix startup failures.
When it reports Ready, use **Open preview** to enter through your signed-in
browser session. These are the same saved track settings the form edits.

Before delivering each user turn, Switchyard installs a small shell helper at
`/home/sprite/.switchyard/previews/<track-id>.sh` and includes its usage in the
agent's instructions. Existing conversations get it on their next turn;
recreating a project or conversation is unnecessary. The transcript displays
the person's original message, with their attribution, rather than the injected
instructions. If helper preparation fails, the user's saved prompt still runs
and the agent is told to use the manual controls.

The helper supports `configure '<JSON>'`, `start`, `status`, `logs`, `restart`
and `stop`; `configure null` restores the project default. Its two-hour
credential is stored outside the checkout, only its hash is saved in SQLite,
and the next delivered turn replaces it. It is limited to the current track,
conversation, machine and prompt sender's continuing membership. Removing
access or retiring the track revokes it. It cannot change project defaults,
mint browser preview tickets, or access provider credentials. As with the
terminal, tracks share a machine; this is not OS-level isolation between
collaborators. The private helper must not be printed or copied into a repo.

In project settings, the owner can save an app directory, startup command and
readiness path. **Configure** on a track saves an override or restores the
project default. Directories are relative to that track's worktree. Changing
configuration stops the affected preview; **Open preview** starts it again.
Track members can configure, open, restart, stop and read logs using their
existing execution permissions. Closed tracks cannot operate previews.

For a Vite app, select its directory and use:

```sh
npm run dev -- --host 127.0.0.1 --port "$PORT" --strictPort
```

Set Vite's `server.allowedHosts` to your preview suffix, for example
`[".preview.switchyard.inevitable.fyi"]`. Keep HMR on the browser's current
host and port; avoid hardcoded localhost HMR URLs. Use `/` as the readiness
path, or an app health endpoint that returns 2xx/3xx. Dependencies must already
exist in the workspace. The command must honor `$PORT` and refuse a collision;
the gateway checks only that allocated port. Port checks require `ss` in the
workspace. Supporting processes, additional ports and writable app data also
need separate locations or allocations for each track.

**Open preview** opens a private tab and waits for HTTP readiness. **Restart**
recreates the managed service; **Stop** ends it; **Logs** reads up to 32 KB of
service output. Failed startup stops automatic retries until another explicit
open/restart. The page includes a link back to the track for corrections. It
shows the live working copy, including uncommitted agent changes.

Each track has a named Sprites service, a persistent port reservation and its
own browser origin. Services do not use the machine's public HTTP service
route: the gateway carries HTTP and WebSocket/HMR over authenticated private
TCP tunnels. A one-minute single-use ticket establishes a host-only, HttpOnly
preview cookie, bound to the signed-in Switchyard session. Membership is checked
on every request and upgrade; open streams are checked on membership events
and every second. Sign-out or removal invalidates that user's preview access.
Provider credentials and gateway cookies never reach the app. These browser
origins share the project's machine and its existing trust model.

Visible HTML pages send an activity heartbeat every 30 seconds. The server
holds a 90-second viewing lease and refreshes a two-minute Sprites Task while
that lease is active. It does not health-poll after the lease expires. After
five minutes without activity it stops the service; opening it starts it again.
The app's CSP must allow the injected same-origin
`/__switchyard/activity.js` script and heartbeat fetch. Apps that block it, or
serve no HTML, stay active only while requests arrive. The `/__switchyard/`
path is reserved. Closing a track, rebuilding or archiving a project removes
its services; failed cleanup is saved for retry. Restarting Switchyard preserves
services and reconciles recent active intent from SQLite.

### Enable gateway routing

Production requires HTTPS on a wildcard preview domain separate from
`PUBLIC_URL`. Prefer a different registrable domain from the application. The
deployment uses `preview.switchyard.inevitable.fyi`, while the app is on
`switchyard.demo.managoat.com`.

1. Provision `*.preview.switchyard.inevitable.fyi` DNS to the cluster ingress.
2. Confirm the existing `letsencrypt-production` DNS01 issuer can issue for
   that zone, or change the Certificate's issuer and domain.
3. Build/publish the new Switchyard image and use `apps/switchyard/k8s`
   in the deployment's Kustomize/Flux configuration. It sets
   `PREVIEW_DOMAIN`/`PREVIEW_PORT` and includes the internal
   gateway Service, wildcard certificate and HTTPS Traefik route.
4. Preserve the original Host header and allow WebSocket upgrades and long
   streaming responses through ingress. Keep the gateway listener private.
   Verify both track URLs and signed-out denial before enabling team use.

Render the manifests with
`kubectl kustomize apps/switchyard/k8s` from the repository root.
`k8s-previews/` remains a compatibility entry point for the same resources. This version
uses one Switchyard replica and its existing SQLite volume; orchestration
locks are process-local. Persist and back up that volume. The production
build bundles the server's transport dependencies into `dist-server/index.js`;
the container runs that bundle.

For local development, `bun run mock` also starts a Sprites protocol fixture
on `:8794` that runs real Node/Vite apps in temporary directories. Its printed
server command enables `PREVIEW_DOMAIN=preview.localhost`,
`SPRITES_URL=http://localhost:8794`, and `SPRITES_TOKEN=sprites_mock`.
`*.preview.localhost` uses HTTP and the explicit gateway port for local testing
only. Node must be installed. `MOCK_PORT` and `MOCK_SPRITES_PORT` allow an
isolated fixture alongside another development session.

The [verification record](docs/track-previews-verification.md) distinguishes
local and live Sprites browser evidence from pending parking and
physical-phone checks. In particular, a Sprites Task does **not** prevent
Fountain from independently marking its conversation parked.

## Whose account is this

This is the one app in the suite where the answer is not "yours", and it is
worth being blunt about because everything else follows from it.

Sign-in is GitHub. So a person here has **no Fountain account**, no key to
paste, and nothing to spend. Every machine runs on the server's single Fountain
key, and the turns are on the deployment. That buys the thing the demo is
actually for — you arrive, you pick a repository, and thirty seconds later an
agent is working in a worktree — at the cost of a server that holds a real
credential and a shared blast radius if it leaks.

It also decides the architecture. There is **no Fountain proxy**. Paddock
forwards a curated list of Fountain paths on the owner's key, which is safe
because the owner is spending their own account. Forwarding anything here would
hand a stranger the account every machine on the deployment is built on. So
every route in `server/app.ts` is a typed operation on something the caller may
reach, `shared/api.ts` is the whole of what the browser can name, and the word
"Fountain" does not appear in `src/` at all.

## A project is a machine

Fountain builds a sandbox from an identity — `(user, agent, environment, vault)`
by id. Change any of those ids and the disk you were using is gone.

So a **project** is exactly one agent, one environment and one vault, made
together at creation and never replaced. Conductor's own definition of a project
is nearly this sentence — "an environment and an agent" — which is why the word
survived the port. Every setting the project panel offers is a mutation of one
of those three records in place, so no configuration change can take the machine
away.

The order they are made in is not stylistic. The environment and the vault exist
before the agent, because the agent is created already pointing at them; an
agent updated afterwards would be one whose identity changed between its
creation and its first machine. `server/projects.ts` unwinds all three if any
step fails, because a half-made project is three orphaned Fountain records and a
row pointing at a machine nobody can build.

## A track is a worktree

Conductor calls these threads, or workspaces. Here they are tracks, because
that is what they are in a yard: parallel lines off one main, each holding
something different, all on the same ground.

Opening one sends a turn that runs `git worktree add`, and you watch it happen
in the transcript. That is not a loading state dressed up — it is the honest
shape of the problem. Making a *conversation* is an API call and takes a moment;
making a *worktree* is work on a real machine and takes a turn. The two cannot
be atomic, so the track exists before its directory does, the ribbon says
"Creating" rather than "Created" until the machine answers, and the composer is
live the whole time because Switchyard saves follow-up prompts on its server
and delivers them when the conversation is ready.

A track started from a pull request, a branch or an issue takes its name from
there, because that is the name the work already has everywhere else. One
started from nothing gets a **yard name** — Crewe, Selkirk, Tarcoola — from
`shared/names.ts`. That is not decoration: the premise of the app is four
tracks at once, and four rows reading "Untitled 2" is a sidebar you decode
rather than read. The name is also the directory, the branch and the thing you
say out loud, so the list is chosen for slugs that survive all three, and a
name is spent for good once used — a closed track's branch outlives its row.

Closing a track runs `git worktree remove` — not `rm -rf`, because the clone
keeps an administrative record of every worktree it cut and a directory deleted
from underneath it leaves that record behind, after which the *next* track with
the same name is refused for a reason nobody can see. The branch is left alone.
It may be pushed, it may be an open pull request, and "close this tab" is not a
gesture that should delete work.

**Close track**, in the header above the transcript, is where that happens, and
it is a dialog rather than an `x` on the rail because the two halves of it pull
opposite ways: the directory goes and the branch stays, and somebody who has
those the wrong way round loses either their uncommitted work or their nerve.
So the dialog reads the worktree's diff before it draws its button. A clean
worktree gets **Close track**; a dirty one gets **Discard 3 files and close**,
because `git worktree remove` refuses a dirty worktree and a close with changes
in it is a discard whether or not the person was told.

## Queue work and close the tab

Every prompt is saved in Switchyard's SQLite database before the server
acknowledges it. Text and attached images stay there while another turn runs.
The **saved prompts** panel shows the order, sender and delivery state; opening
the track on another device reads that same queue. Closing a tab, changing
tracks, or restarting the Switchyard server does not discard waiting work.

`server/prompt-queue.ts` runs independently of browser connections. Every two
seconds it checks the first outstanding prompt on each track, refreshes the
clone credential, checks the sender still has access, and delivers when the
conversation is idle. A busy machine or a failed readiness check leaves the
prompt saved for another attempt. Up to 20 prompts can wait on a track, with
12 MiB of serialized text and image data per prompt.

The sender or project owner can cancel a waiting prompt. Closing the track,
rebuilding or deleting its project cancels its pending queue. Removing a
sender's access prevents their waiting instructions from being delivered.
Once delivery has started, use **Stop this turn** instead of cancellation.

A unique `requestId` on `POST /api/tracks/:id/prompt` makes a repeated HTTP
submission return the same receipt. **Saved** means accepted by Switchyard;
after Fountain accepts delivery, its transcript owns the running turn.
Fountain does not offer an idempotency key for that second handoff. A lost
response or a Switchyard restart during delivery therefore leaves the prompt
as **Delivery unconfirmed**, with later prompts on that track held behind it.
Check the transcript, then cancel it or explicitly send it again. An uncertain
delivery is never automatically replayed.

The queue lives on the deployment's existing single SQLite volume; its
durability depends on that volume. It does not recover a lost Fountain machine
or guarantee that an accepted agent turn completes successfully.

`GET /api/tracks/:id/queue` reads the queue, `DELETE .../queue/:promptId`
cancels an item, and `POST .../queue/:promptId/retry` explicitly retries a
refused or unconfirmed delivery. All three use the track's existing access
checks. Delivered and cancelled items release their image payloads and retain
their request ids as receipts.

## The transcript is the agent's own stream, formatted

Fountain's conversation stream is forwarded byte for byte — `server/tracks.ts`
forwards the response one chunk at a time with backpressure, without parsing
or accumulating the transcript. Removing track or project access cancels the
upstream request and the browser stream, including an idle connection. So the
deltas arrive as the runtime produced them, and everything below is about not
throwing that away on the way to the screen.

The shared parser (`@managoat/fountain-app/acp`) says what blocks a turn has
and in what order. It flattens each tool call to a name and a summary, which is
all a preview bubble elsewhere in the suite needs and not enough here: rendered
from that alone, a turn that read four files, ran two commands and rewrote a
module is eight identical grey chips reading `execute command=…`. That sameness
— not the latency — is what makes a transcript over a real agent feel generic.

So switchyard reads the same events a second time (`src/lib/tools.ts`) for the
detail the block dropped, and joins it back on `toolCallId`. Nothing in that
pass can change the shape of the transcript, and the fifteen other apps on the
shared parser are untouched. On top of it:

- **The reply is markdown**, because that is what the agent writes.
  `src/lib/md.ts` is a renderer with no dependency and two properties a live
  transcript needs: it escapes before it does anything else, so bytes off
  somebody's repository can never be markup; and it is tolerant of half a
  construct, because every chunk arrives mid-sentence. An unterminated fence
  renders as an open code block rather than swallowing the rest of the turn.
- **A call says what it did to what** — `Ran bun test`, `Read server/app.ts`,
  `Searched blocksForTurn` — with paths shown relative to the track's own
  worktree, and its output folded underneath. An edit shows the lines it
  changed, framed by the ones it did not.
- **Reasoning is open while the turn is live** and one line afterwards.
  Watching a machine think is the most legible thing it does; on the second
  read it is between you and what the agent decided.
- **The indicator names what is happening** — `Running bun test`, and a
  counter — rather than saying "Working". The two questions somebody has while
  watching a machine work are *what is it doing* and *has it hung*, and a row
  of animated dots answers neither. It counts off a timer, not off arriving
  chunks, because a turn that has genuinely stalled is exactly the one that
  stops re-rendering.

## Working on this with somebody else

Invite them by GitHub username, to **a track** or to **the whole project**. The
box is the same one either way: it autocompletes over everyone who has signed
in to this deployment, which does mean it will confirm whether a given login has
an account here — a trade this deployment has accepted, because the alternative
only suggests people you have already shared with and is therefore useless for
the first invitation anybody sends. It returns what GitHub already publishes:
login, display name, avatar. Never an email.

Two things follow from sign-in being GitHub rather than an email:

- **You can invite somebody who has never been here.** A username with no
  account is resolved against GitHub and the invitation waits on their account
  until they sign in. It is stored against GitHub's **numeric id**, not the
  login — logins are renameable, and one freed by a deleted account can be
  taken by somebody else, so an invitation matched on the name would eventually
  attach to the wrong person.
- **Or you can send a link.** One per track and one per project; minting a new
  one is therefore the revoke. `/j/<token>` serves both, because a browser
  holding one has no idea which it is and should not need to. Anyone who opens
  it and signs in with GitHub joins — it is not anonymous, because a shared
  transcript that cannot say who asked is worse than no transcript. Only the
  hash is stored, so a link genuinely cannot be shown to you twice. Revoking
  stops anyone new getting in; people already in stay until you remove them.

  A track link lasts a week; a project link lasts two days. The shorter number
  is the whole argument for having two: a project link is the widest thing
  switchyard hands out, so it is the one that should least survive being
  forgotten in a chat scrollback. Nobody is worse off — minting another is one
  button.

### The two grains, and the line they share

**A track invitation** is one branch in one directory. The member gets that
track's transcript, files, diff, terminal and prompt box, and does not see the
project's other tracks or open one. `trackAccess` decides that per row.

**A project invitation** is every track on the machine — the ones open now and
the ones opened next week — plus the ability to cut tracks of their own. It is
a separate, deliberate act by the owner rather than something a track invite
grows into, and it lives in its own dialog off the rail. `projectAccess`
decides it, and the invitation is written against the person rather than
against the tracks, so nothing has to be back-filled when a new one opens.

For a long time only the first existed, on the argument that inviting somebody
to a *branch* is an everyday act and inviting them to your *machine* is not.
That is true and it is still the default. What it missed is that working with
the same person across a week of branches, re-inviting them to each one, is not
an everyday act either — and, more to the point, that a track invitation
already costs most of what a project invitation costs, because they run on one
box. See *what sharing actually costs*, below. The wider one adds reading the
other transcripts and opening tracks: real, worth a separate decision, not a
different order of trust.

**Neither reaches the project's controls.** Settings, packages, secrets,
rebuild and delete stay with the owner, and that is the line both memberships
have in common. `projectOf` is the only door to them and it selects on
`user_id`, so a member is *not found* rather than refused.

Two smaller rules fall out of project members being able to open tracks:

- **Whoever cut a track can rename and close it.** Not any member — being
  invited to help on a branch is not being handed the ability to end it for
  everybody else in it — but somebody who may make a directory on the machine
  and then may not tidy it up leaves the owner sweeping up after their guests.
- **One person holds one grade of access to a project.** Inviting somebody to
  the whole project deletes any track rows they held on it, and inviting a
  project member to a single track is refused as the no-op it is. So removing
  them from the project is the whole revoke — including a track they were named
  on beforehand — which the dialog says out loud, because the alternative is a
  narrower row that survives invisibly at exactly the moment somebody is trying
  to take access away. A track's people list marks those rows *whole project*
  and puts their × in the project's dialog, where it works.

Once a track is shared, each prompt is prefixed `[from @login]` so the
transcript can say who asked and the agent knows who it is working for.
`shared/author.ts` writes it and the transcript reads it back off. It is added
only when a track actually has more than one person in it — a solo track
labelled with your own name reads as the app talking to itself.

### Who is here, and who is typing

Two clocks with opposite requirements, which is the whole of `server/presence.ts`.

**Watching** lasts 45 seconds and is refreshed by a heartbeat. It is generous
on purpose: it has to outlive a slow tab and a closed laptop lid, and a name
that lingers briefly is a much smaller lie than a name that vanishes while its
owner is still reading. Closing a track says so explicitly rather than waiting
for the lease, because leaving is the one moment we actually know.

**Typing** lasts 3 seconds and is refreshed by keystrokes. It is ungenerous for
the opposite reason: "@ana is typing…" left up over an empty chair is worse
than no indicator, because it is the signal people wait on before sending
something themselves. It is a *pulse*, not a state — the browser says "still
typing" and the server gives that three seconds, so a tab that dies mid-word
stops claiming without having to apologise for it.

Neither is persisted. Presence that survived a restart would be a list of
people who are not there.

Presence is per **track**, and the `here` event carries an audience: the owner,
everybody in the project, and that track's own members — nobody else on the
project's channel. An event naming a track is an event that says the track
exists, and a member who cannot see it should not learn otherwise from a
heartbeat.

### What sharing actually costs

The worktrees are separate directories on **one machine**, and the separation
between them is the rule in the system prompt rather than a boundary the kernel
enforces. So somebody you invite can ask the agent for things outside the
branch you invited them to, including the environment's secrets. Both invite
dialogs say this where the decision is being made rather than only here.

This is also the honest reason the project grain exists rather than being
refused on principle. A track invitation *already* reaches the whole box if the
person asks the agent nicely; pretending otherwise while forcing an owner to
send eight track invitations to the same colleague was ceremony, not a
boundary. The boundary that is real is the one below.

The one real mitigation is the same distinction the project panel already
draws: an **environment** secret is an env var inside the box and anything on
the box can read it; a **vault** secret never reaches the machine, because
Fountain's egress broker substitutes it in flight. The clone token is a vault
secret for exactly this reason — a member cannot print it, because the machine
does not have it.

Opening a pull request is deliberately open to members, and that is a decision
rather than an oversight: a member can already prompt the agent, the machine
already holds a credential that can push, and the agent will open one if asked.
A button that refused what the prompt box allows would be theatre.

### Keeping tracks apart is a prompt, and that is a real limitation

There is no chroot here and no per-track permission. Two worktrees on one disk
are kept from trampling each other by a **rule the agent follows**, stated in
`shared/spec.ts` and injected as the system prompt on every turn.

The app does what it can to make that rule stick. It is said three times over —
in the system prompt, in the turn that cuts the worktree, and in the header of
every prompt switchyard sends itself — and `shared/spec.test.ts` asserts on the
sentences, so losing one in an edit fails a build rather than being discovered
by two tracks committing to the same branch. A person's own instructions are
appended *after* the rule rather than before it, so an `AGENTS.md` that opens
with "ignore previous instructions" does not get to go first.

That is mitigation, not enforcement, and this paragraph exists so nobody has to
find that out from behaviour.

## The GitHub App, and why it is not a token

Paddock's README says there is no GitHub App and there will not be one, and it
is right for paddock: only the owner adds a repository there, so an App would
buy a picker and a worse credential. Switchyard is the case paddock names as the
exception — the app needs to know *which repositories this person can offer*
before they have typed anything.

An App answers that, and the credential it gives you is strictly better than the
alternative:

- **A personal access token is scoped to everything you can reach.** An
  installation token is scoped to the repositories you picked when you installed
  it. The difference matters more than usual here, because what is on the other
  end is an agent with a shell.
- **It expires in an hour.** Which is a genuine cost, not a footnote: Fountain
  hands the vault to a sandbox when a *session* starts, so a project you come
  back to the next morning has a dead token in it. Every path that is about to
  make the machine talk to GitHub re-mints first (`refreshCloneToken`), and
  GitHub's own token cache makes the repeats nearly free. The symptom if this
  were missing is `git push` failing as an authentication error mid-turn, which
  reads like a permissions problem and is not one.
- **The token never lands on the machine.** It goes in the project's *vault*
  under `GITHUB_TOKEN`, and Fountain's egress broker keeps a two-entry catalog —
  exactly `GITHUB_TOKEN` and `GH_TOKEN` — that attaches git's `x-access-token`
  basic auth in flight. The sandbox holds a placeholder. That name is
  load-bearing: a GitHub *connection* is brokered too, but under
  `GITHUB_ACCESS_TOKEN` and as a bearer, which git over HTTPS does not use. A
  connection buys the agent the GitHub API and not a checkout.

The same App is the identity provider, so "sign in" and "which repositories may
we see" come from one registration. `GET /user/installations` with the *user's*
token is the join, and it is the correct question: asking the App would list
every account that has ever installed switchyard.

Two round trips, in either order. Somebody signed in with no installation is not
a broken state — it is where everyone is for ten seconds, and where anybody who
declines stays.

## The terminal is real, and it is not a PTY

Fountain deliberately has no exec: reads of a sandbox are free, every write is a
turn. That is the right boundary for Fountain and it is why paddock's terminal
is a Claude Code prompt rendered as scrollback.

Switchyard goes one layer down. Fountain's sandboxes run on
[Sprites](https://sprites.dev), and a sandbox tells you the name of its sprite
(`sandbox.sprite_name`), so a server holding `SPRITES_TOKEN` can talk to the same
machine directly. That buys two panels a conversation cannot: a terminal, and a
run command whose output you watch.

Three things about it, all of which the UI says rather than leaving to be
discovered:

- **It is optional.** No token, no terminal — and everything else still works,
  because everything else goes through Fountain. The panel names the missing
  variable.
- **It is out of band.** These commands are not turns. They do not appear in the
  transcript and they do not queue behind the agent's one-turn-at-a-time lock,
  so you can run `git status` while the agent is mid-edit. That is the feature,
  and it is why `resolveCwd` pins every command inside the track's own worktree:
  a text box that could `cd ..` would undo the rule the agent is told three
  times to follow.
- **It is one request in, one response out.** `ls`, `git log` and `npm test` are
  exactly right. `vim` and `top` are not.

## CPU, memory and disk, at the quiet end of the project's row

The same exec buys one more thing, and it is deliberately the smallest thing on
the screen: `cpu 34% · ram 1.4/4G · disk 12/98G`, grey, at the right-hand end of
the crumbs. Nobody opens switchyard to watch a gauge. But four tracks on one
project share one CPU allowance, one memory limit and one disk, and when the
fourth `bun install` of the afternoon starts swapping, "is it me or is it the
box?" has no other way to be answered from in here.

It is on the project's row rather than in the dock because that is where the
width is. The dock's tab strip is the more obvious home and does not work: it
sits in the inspector column, which is 340px at its narrowest and has three tabs
in it already, so the readout ends up shrinking and truncating to `ram 9.9/1`.
`flex: none` is the fix for the truncation and the crumbs is the fix for the
room — the line drops out whole at 1100px, where the window stops having any to
spare.

Two decisions in `server/vitals.ts` are worth knowing:

- **Every figure is independently optional.** They come from `cpu.max`,
  `cpu.stat`, `memory.current`, `/proc/meminfo` and `df` — a set no single
  kernel, runtime or image is guaranteed to have all of. The probe reads what is
  there and the parser reports the rest as *absent*, never as zero. "0% CPU" and
  "we could not tell" are different claims and only one of them is ever true.
- **The pairs are not mixed.** The cgroup's `current` against its `max`
  describes the container; `/proc/meminfo`'s total against available describes
  the box. One number from each would describe neither, so the parser takes
  whichever pair is whole.

The readout renders nothing at all when there is nothing to say — no token, a
machine asleep, a kernel keeping its counters somewhere else. A row of dashes
would read as a fault on a machine that is working perfectly well.

## Sixteen palettes, in the foot of the rail

The theme picker carries the editor canon — One Dark, Dracula, Nord, Tokyo
Night, Catppuccin, Night Owl, Monokai, Gruvbox, Solarized both ways, GitHub and
One in their light versions — alongside this app's own Switchyard and Daylight.
It is not decoration. What fills this screen is a transcript full of diffs, and
somebody who has read diffs in Gruvbox for six years reads them faster in
Gruvbox.

The whole mechanism is one attribute on `<html>`: every colour in `styles.css`
is a custom property declared under `[data-theme="…"]`, and nothing below the
palettes hard-codes a hex. Two details follow from that and are worth knowing
before adding a theme, both explained in `src/lib/theme.ts` — the selectors are
not anchored to `:root`, so the picker's sixteen swatches are live palettes
rather than sixteen hand-written gradients; and the choice is applied by an
inline script in `index.html` before the stylesheet paints, because a module
import runs one full frame too late and that frame is near-black.

`src/lib/theme.test.ts` fails the build if a theme in the list has no complete
block in the CSS. A missing token there does not break anything loudly — it
falls back to the default palette's value, so a Dracula shell with one
near-black panel in it looks like a design choice.

## What is not here, and why

| Conductor has | Switchyard | Because |
| --- | --- | --- |
| Open a local project | a card, disabled, saying so | The machine is in the cloud. There is no folder on your computer for it to open. |
| Multiple tabs per thread | one conversation per track | A second tab on the same worktree is two agents editing one branch — the thing the whole app is arranged to prevent. |
| An editor | read-only files, `git diff` beside them | To change something, ask for it in the track. The panel says so rather than leaving people hunting for a save button. |
| A run panel with long-lived processes | one command at a time | Sprites' exec is request/response. A dev server that outlives the request needs process supervision that is not built yet. |

Everything else — the repository picker, create-from-a-PR/branch/issue, the file
tree, changes, GitHub checks, opening a pull request, the terminal — is real.

## Where things live

| It knows | From |
| --- | --- |
| who you are | a session cookie over a GitHub App OAuth token, encrypted at rest |
| which repositories you can offer | `GET /user/installations` with your token, live |
| which project is which | a row — a project's name and repository are switchyard's ideas, not Fountain's |
| whether a machine is up | Fountain's conversation list, live. Nothing about a machine is stored. |
| which track is behind | the revision in its `channel_id` versus the project's |

`shared/spec.ts` and `shared/ids.ts` are the contract — what switchyard asks the
machine for, and the four places a track's slug is load-bearing at once
(a directory, a branch, a channel id, and a name in the rail). They are the two
files the suite never shares, because they are the product.

## Deploy

Push to `main`; CI builds `ghcr.io/managoat/switchyard` and pins the sha into
`k8s/deployment.yaml`. Flux in
[jhgaylor/home-cloud](https://github.com/jhgaylor/home-cloud) reconciles it.

Unlike the rest of the suite, this one needs real secrets in the cluster — see
`k8s/infisicalsecret.yaml` for the folder and the list. The `secretRef` is
optional on purpose: before it syncs the app still serves and says on screen
which variable it is missing, which is a better failure than a pod that will not
start.

## License

MIT — see [LICENSE](../../LICENSE).
