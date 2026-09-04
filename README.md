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
| `SPRITES_TOKEN` | optional — with it the terminal and the run panel are live |
| `DATA_DIR` `STATIC_DIR` `PORT` | as everywhere else in the suite |

Nothing needs registering on Fountain: the browser never talks to it, so there
is no OAuth client and no CORS origin.

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
every route in `server/app.ts` is a typed operation on something the caller
owns, `shared/api.ts` is the whole of what the browser can name, and the word
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
live the whole time because Fountain queues a prompt behind the turn already
running.

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

## Working on a track with somebody else

Invite them by GitHub username. The box autocompletes over everyone who has
signed in to this deployment, which does mean it will confirm whether a given
login has an account here — a trade this deployment has accepted, because the
alternative only suggests people you have already shared with and is therefore
useless for the first invitation anybody sends. It returns what GitHub already
publishes: login, display name, avatar. Never an email.

Two things follow from sign-in being GitHub rather than an email:

- **You can invite somebody who has never been here.** A username with no
  account is resolved against GitHub and the invitation waits on their account
  until they sign in. It is stored against GitHub's **numeric id**, not the
  login — logins are renameable, and one freed by a deleted account can be
  taken by somebody else, so an invitation matched on the name would eventually
  attach to the wrong person.
- **Or you can send a link.** One per track; minting a new one is therefore the
  revoke. Anyone who opens it and signs in with GitHub joins — it is not
  anonymous, because a shared transcript that cannot say who asked is worse
  than no transcript. It lasts a week, because the thing it is for is "have a
  look at this with me" rather than standing access, and only its hash is
  stored, so it genuinely cannot be shown to you twice. Revoking stops anyone
  new getting in; people already on the track stay until you remove them.

**The unit of sharing is a track, not a project.** A project is a machine with
a disk, a settings panel and a bill. A track is one branch in one directory.
Inviting somebody to a branch is a thing people do every day; inviting them to
your machine is not, and an app that offered only the second would be offering
the wrong thing under the right name. So a member gets that track's transcript,
files, diff, terminal and prompt box — and does not see the project's other
tracks, cannot open one, cannot change the machine, and cannot close the track
they are in. `trackAccess` decides that per row, which is what makes the rule
true by construction rather than by everyone remembering it.

Once a track is shared, each prompt is prefixed `[from @login]` so the
transcript can say who asked and the agent knows who it is working for.
`shared/author.ts` writes it and the transcript reads it back off. It is added
only when a track actually has more than one person in it — a solo track
labelled with your own name reads as the app talking to itself.

### What sharing a track actually costs

The worktrees are separate directories on **one machine**, and the separation
between them is the rule in the system prompt rather than a boundary the kernel
enforces. So somebody you invite can ask the agent for things outside the
branch you invited them to, including the environment's secrets. The invite
dialog says this where the decision is being made rather than only here.

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
