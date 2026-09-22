---
type: ADR
title: "Each person brings their own agent subscription, and a project spends its owner's"
description: "A person connects Claude Code (subscription token or Anthropic key) or Codex (ChatGPT subscription by device-code sign-in, or OpenAI key) once, in a first-run walkthrough; Ravix keeps it in one Fountain inference credential set per person and points every project's agent at its owner's set. Needs Fountain v0.17 or newer for the sets and the hosted Fountain of 2026-09-21 or newer, with linking switched on, for ChatGPT; the deployment runs neither yet. Fountain caps ChatGPT subscriptions per account, and Ravix is one account, so that cap is a count of people."
tags: [architecture, billing, onboarding, fountain]
status: draft
adr: "0005"
adr_status: "Proposed"
date: 2026-09-20
generated: { by: claude-fable/5.1, at: 2026-09-20T23:40:00-04:00 }
stale_after: 2026-10-20
---

# 0005 — Each person brings their own agent, and a project spends its owner's

**Status:** Proposed. Built and tested against a scripted Fountain and the local
mock: the walkthrough (`RavixWeb.OnboardingLive`), the credential context
(`Ravix.Accounts.Inference`), Codex on a ChatGPT subscription by device-code
sign-in (the same two modules, against Fountain's
`docs/build/chatgpt-subscriptions.md`), and projects built on, rebuilt on and
moved onto their owner's credential set (`Ravix.Projects.Machine`). **Not
verified against a real Fountain, and the ChatGPT sign-in not against a real
ChatGPT account.** Two things are unmet, and each is named where it matters
below: the deployed Fountain is too old for any of this, and nothing tells a
person *why* a track stopped after they replaced a credential or their
subscription stopped serving.

## Context

Every machine ran on the deployment's own Fountain credentials. The sign-in
page said so: "there is no key to paste, and the turns are on the house." That
stops being affordable the moment anybody but the operator signs in, and
Fountain now lets a model credential belong to somebody other than the account.

Ravix is one Fountain account for everybody (`Ravix.Fountain`). A person here
signs in with GitHub and has no Fountain account, so "their own subscription"
cannot mean the account's credential. Fountain offers two ways to hold somebody
else's:

- **Inference credential sets** (Fountain ADR 0053, v0.17.0): named groups of
  provider credentials on one account. An agent names the set its conversations
  run on with `inference_credential_id`.
- **Claimable principals**: a tenant of its own per customer, with its own
  encryption key. Time-limited until claimed by a person with a Fountain login,
  which nobody here has.

Fountain's ADR 0053 says a business with many customers should use principals,
not sets. That advice is about isolation between customers who must not share
an account's blast radius. Ravix's people already share one: one key builds
every machine, and Ravix is what stands between them. A principal per person
would not change that, and cannot outlive a week without a Fountain login to
claim it.

Two facts about sets shaped the rest:

- **A conversation is bound to the revision of the set it started on.** Any
  write to the set, to any of its four slots, bumps the revision, and Fountain
  then refuses the conversation's next prompt (`inference_source_changed`)
  rather than spend a different credential than it began with. There is no
  rebind; the remedy is a new conversation.
- **A Codex machine is bound to one credential source for its whole life.**
  Codex keeps a shared auth directory on the disk, so a second source on the
  same machine is refused (`codex_inference_conflict`).
- **A ChatGPT subscription is not a value.** Fountain's ADR 0060 links one by
  a device-code sign-in: the person types a one-time code at
  `auth.openai.com`, Fountain keeps and renews the tokens, and the account
  holds a named *grant* that a set names by id (`chatgpt_grant_id`). No
  route returns a token. A grant does nothing until a set names it, and once
  one does, Codex on that set runs on the subscription and on nothing else:
  an unusable subscription refuses the run (`409 chatgpt_grant_unusable`)
  rather than falling back to a key or to the platform's account. Only Codex
  reads the grant. Linking is behind Fountain's `chatgpt_subscriptions`
  flag, on for every hosted account since 2026-09-21 and off on a
  self-hosted Fountain unless its operator forces it; `/api/auth/me` reports
  it as `chatgpt_subscriptions_enabled`. An account holds at most
  `CHATGPT_GRANT_CEILING` grants, five by default.

## Decision

**One set per person, made the first time they connect anything**, named
`ravix:<user id>`. The value goes to Fountain and cannot be read back by
anybody. The `users` row keeps the set's id, which agent they chose (`claude`
or `codex`) and whether it was a subscription or an API key.

**Codex on a ChatGPT subscription is one grant per person, named
`ravix:<user id>` like the set, on that set.** The walkthrough starts the
sign-in (`Inference.begin_link/1`), shows the code and the page to type it on
--- as a link only when Fountain named an `https` page on `auth.openai.com`,
as text otherwise --- and polls Fountain (`poll_link/2`) until ChatGPT has
approved it. Approval names the grant on the person's set, which is the whole
of what makes their Codex projects run on it, removes their OpenAI key if they
had one, and records the choice as `codex` paid by `subscription`. A second
sign-in by somebody who has a grant already *reconnects* it rather than
linking another, which is also the repair for a subscription Fountain has
stopped honouring. Choosing an API key for Codex afterwards clears the grant
from the set, or the key would sit there unused. Arriving on the step reads
Fountain's open attempts, so a reload during a sign-in shows the same code,
and reads the flag, so a Fountain where nobody may link says so instead of
offering a button.

**A project spends its owner's set, whoever is working in it.** The agent is
created with `inference_credential_id` set to the owner's set and
`allowed_inference_credential_ids: []`, so no launch can name another. A
teammate needs nothing of their own to be useful, and the owner is billed for
their turns; the walkthrough says so in those words. It is also the only
arrangement Codex permits, since a project is one machine.

**The owner's agent is the project's runtime**, when this Fountain runs it. A
catalog that lists runtimes and omits theirs refuses the project
(`agent_unavailable`) instead of building it on the other agent with the wrong
provider's key to spend.

**Projects that predate their owner's credential are moved onto it lazily**, on
the way to waking the machine (`Machine.adopt_credentials/2`). Every track
opened and every queued prompt already passes through there, so it needs no
job, and the `projects` row records which set the agent was last pointed at so
the usual answer is a comparison. Conversations already open keep spending
what they were spending; Fountain guarantees that.

**Ravix reserves the account's default set.** Fountain makes the first set an
account ever creates its default, which is what an agent with no set runs on.
On a fresh deployment that would be the first person to connect, paying for
everybody who had not. An empty `ravix:house` set is made first.

**The agent step is also the account dialog.** `RavixWeb.Live.AgentPanel`
is one component rendered by the walkthrough and by the workspace's account
dialog (the "account" link in the rail, and the new-project form's nudge), so
changing the agent, replacing a credential or reconnecting a subscription
weeks later is the same page as the first time, and shows the subscription's
state as Fountain reports it: connected, disconnected, reconnect required, or
spent until a time.

**The walkthrough is not a gate.** `/welcome` is shown to somebody who has no
project and has never finished or dismissed it. Every step can be skipped:
somebody invited into a teammate's project needs no subscription, and a scratch
project needs no repository. Somebody who arrives by an invitation lands on
what they were invited to.

## Consequences

- **The deployment must run Fountain v0.17.0 or newer before anybody can
  connect.** `fountain-deploy` pins v0.16.0. Until then `connect/2` answers
  "this Fountain is too old" and everything else behaves as it did: projects
  are still built, on the deployment's default credentials.
- **How many people can run Codex on a subscription is a deployment-wide
  number.** Fountain caps grants *per account*, and Ravix is one account, so
  the default ceiling of five is five people. The sixth is told to ask
  whoever runs the deployment; raising `CHATGPT_GRANT_CEILING` on the
  Fountain is the fix. The other limits --- three sign-ins open at once, ten
  started an hour --- are per account too, and are said in those words.
- **A ChatGPT account links once per Fountain account.** Two people here
  approving codes with the same ChatGPT account is refused for the second
  (`account_already_linked`), and the page does not say whose it is, because
  the grant's name says who.
- **The ChatGPT sign-in has been run against the mock and a scripted
  Fountain only.** Fountain itself says the first links on the hosted
  platform are the test. What a real approval, renewal and exhaustion look
  like from here is unverified.
- **Replacing a credential ends that person's open tracks, in every project
  they own**, because the revision covers the whole set, and naming or
  clearing a grant is a write to it. The page warns before the button is
  pressed. What is unbuilt: a track refused with `inference_source_changed`
  shows Fountain's sentence and no way forward, and one refused with
  `chatgpt_grant_unusable` --- the subscription disconnected, expired, spent
  until a time, or reconnect required --- shows the same. Each should say
  which subscription and why, and send the owner to the agent step to
  reconnect it.
- **Somebody who skips the agent step can still create a project**, and it runs
  on the deployment's default set if that holds anything. Refusing instead
  would have stopped every project on the day this shipped, since no deployed
  Fountain can hold a person's credential yet. Once it can, making the
  credential required is a one-clause change in `Ravix.Projects.create/2` and a
  decision worth taking deliberately.
- A project's secrets can still name `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or
  `CLAUDE_CODE_OAUTH_TOKEN`, and Fountain lets a vault or environment secret of
  that name override the set. That is an owner overriding their own billing, so
  it is left alone, but it is a second place the answer to "who pays" can live.
- A Claude subscription cannot run `claude-fable-5-1` through Fountain, which
  refuses it on the OAuth path. The default model stays `claude-opus-5`.

## Alternatives considered

- **Claimable principals, one per person** — expire unclaimed after seven days,
  and nobody here has a Fountain login to claim one with.
- **The credential as a vault secret on each project** — Fountain does honour
  it, but it is one copy per project to rotate, and a teammate with project
  access could replace it.
- **Each person's own set on each conversation they start** — bills whoever
  typed rather than whoever owns the machine, and Codex refuses a second source
  on one machine outright.
- **Require a credential before the first project** — see Consequences; right
  eventually, wrong on the day the deployed Fountain cannot hold one.
- **A "current step" column for the walkthrough** — a second account of facts
  already recorded: a credential on the person, an installation on GitHub.
