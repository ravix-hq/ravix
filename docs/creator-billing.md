# Creator billing: Fountain verification

Linear RAV-17, ADR 0009 phase 6 and the phase 1 billing checks. This records
what Fountain actually does, so the implementation behind
`RAVIX_CREATOR_BILLING` can bind a dedicated track's conversations to the
track creator's credential set. [Implementation](#implementation) at the end
says what Ravix built on it, and where it deviates.

## Sources and method

- **Fountain source:** `managoat/fountain` at `b0dae6cc` (2026-09-28, after
  `git fetch`). The brief names `~/dev/binarybourbon/fountain`, which is not
  on this machine. This is the same public repository. In this document,
  Fountain paths are relative to `apps/fountain/` unless they start with
  `decisions/` (Fountain's own ADRs). Ravix paths are relative to this
  repository at `4b56668`.
- **Deployed Fountain:** read-only `GET https://managoat.com/api/openapi.json`,
  API version `0.21.0`. The deployed spec matches the source on everything
  below:
  - `ConversationCreateRequest` accepts `inference_credential_id`.
  - `Agent` carries `allowed_inference_credential_ids`.
  - `ConversationReapplyRequest` has no credential field.
  - There is no `PATCH /conversations/{id}`.
  - `inference_source_changed`, `codex_inference_conflict`,
    `chatgpt_grant_unusable`, `inference_credential_not_allowed`,
    `inference_credential_unusable` and `exhausted_until` are all documented.
- **No writes.** Nothing was written to Fountain. No credential set, grant,
  agent or conversation was read with Ravix's account, and no credential
  value was read or printed.
- **Still to do live.** ADR 0009 (`decisions/0009-workspaces.md:321-326`) also
  asks for *live* deployed checks before activation. These are listed under
  [Before enabling](#before-enabling).

## Verdicts

| Question | Answer |
|---|---|
| Can a conversation name a set other than its agent's? | **Yes.** `inference_credential_id` on create. The agent's allowlist must admit it, and the set must belong to the same Fountain account. All Ravix sets are on Ravix's one account. |
| Is that set pinned across wakes, resumes and replacements? | **Yes, for the conversation's life,** including a wake onto a new machine. Any change to the source refuses the next turn (`409 inference_source_changed`). A new conversation is pinned only to what *its* create request names. |
| What wins among override, agent set, env vars and secrets? | A provider-named env var or secret wins over the set; a vault secret wins over an environment variable. The one exception is a Codex run on a set that names a ChatGPT subscription. Ravix must keep provider-named names out of creator-billed launches. |
| Can a live conversation be re-bound in place? | **No,** for Claude or Codex. Conversion is always a new conversation, and the runtime's session starts fresh. |
| Can the new Codex conversation use the same sandbox? | Only if the sandbox's Codex binding allows it (see §3). Otherwise it needs a new sandbox. |
| Does Fountain say "out of quota until 3pm"? | **Only for Codex on a ChatGPT subscription** (`reason: "exhausted"`, `until`). A Claude subscription or any API key has no structured status: the turn fails with free text. |

## 1. Per-conversation override

### How a conversation names its set

- **The attribute** is `inference_credential_id`, the set's id, on
  `POST /api/conversations`:
  - Described at `lib/fountain_web/schemas.ex:764-776`.
  - Read on fresh launch (`lib/fountain/conversations/launch.ex:97-102`),
    attach (`:405-410`), channel start-or-resume (`:806-811`) and channel
    lookup (`:1069-1074`).
  - Kept on queued launches (`lib/fountain_web/controllers/conversation_controller.ex:715`).
  - Unknown request keys are ignored, not rejected (`conversation_controller.ex:712-713`).
    A misspelled key such as `inference_credential_set_id` would therefore
    silently run on the agent's set.
- **Validation** is `resolve_inference_credential_id/3`
  (`lib/fountain/conversations.ex:3830-3842`). It checks two things in order:
  - **The agent admits the set:** `Agent.credential_set_allowed?/2`
    (`lib/fountain/agents/agent.ex:164-195`). The agent's own
    `inference_credential_id` always passes (`:166-171`). A nil allowlist
    admits every set the account owns (`:173-182`). A list admits its members
    (`:184-193`). Anything else is refused (`:195`). A refused set is
    `422 inference_credential_not_allowed`
    (`lib/fountain_web/controllers/fallback_controller.ex:134-141`).
  - **The account owns the set:** `InferenceCredentials.get_set(id, user_id)`.
    A foreign id reads as `404 inference_credential_not_found`.
- **The field's semantics** are in `agent.ex:58-64` ("nil = all current/future
  sets the tenant owns, [] = none") and `schemas.ex:1400-1405` ("an empty list
  forbids overriding; a non-empty list is an allowlist. The agent's own set
  always passes").
- **Updating the allowlist** is `PATCH /api/agents/:id` with
  `allowed_inference_credential_ids`. That field is a whole-array replace, not
  an append.
  - One transaction updates the row and inserts an immutable version
    (`lib/fountain/agents.ex:168-200`).
  - There is no compare-and-swap. Two concurrent read-modify-writes both
    succeed, and the later one drops the earlier one's addition.
  - The allowlist is checked **only at admission**. Changing it neither
    admits nor evicts conversations that already exist.

### Pinning

- **Admission stores the resolved source.** It writes
  `inference_credential_id: inference_source.set_id` and
  `inference_source: Source.dump(...)` (`launch.ex:145-148`). After that, the
  stored source decides the set, not the agent
  (`lib/fountain/conversations/inference_resolution.ex:43-53`,
  `lib/fountain/inference_credentials/resolver.ex:26`).
- **Every turn** re-checks the stored source under the source lock
  (`lib/fountain/conversations.ex:1591-1605`).
- **Wake, reattach and provision** revalidate against the stored source and
  refuse a different one (`lib/fountain/conversations/inference_binding.ex:72-80`).
- **A wake onto a replacement machine** keeps the same conversation row
  (`lib/fountain/conversations/wake.ex:684-688`), so it keeps the same pin.
- **Rotating, replacing or deleting the set** makes the next turn
  `409 inference_source_changed` (`fallback_controller.ex:143-154`). The set's
  `revision` changes on every key write, through the trigger in
  `priv/repo/migrations/20260913120000_bind_inference_sources.exs`.
- **What is not inherited.** A *new* conversation is pinned only to what its
  own create request names.
  - Ravix sends `fresh: true` on every create (`lib/ravix/fountain.ex:434-447`),
    so every Ravix create (thread start, retry, recovery, conversion) must name
    the payer's set itself.
  - Fountain's team successors do not carry an override (`lib/fountain/team.ex:385-401`).
    Ravix does not use them.

### What Ravix does today

- **Home agents are locked.** The home project agent is created on the
  owner's set with `allowed_inference_credential_ids: []`, the empty-allowlist
  lock (`lib/ravix/projects/machine.ex:523-531`, ADR 0005).
  `adopt_credentials/2` re-sends `[]` whenever the owner's set changes
  (`machine.ex:222-236`).
- **Runtime agents are created without an allowlist**
  (`lib/ravix/projects/runtime_agents.ex:104-121`). A nil allowlist is Fountain's
  "every set on the account". Because every Ravix person's set is on the same
  Fountain account, those agents admit **any** Ravix user's set until
  `allow_source` first writes a list.
- **Dedicated tracks under maintenance** already use a per-conversation
  override. `Maintenance.adopt/2` puts the **owner's** set on the launch
  (`lib/ravix/tracks/sandbox/maintenance.ex:52-56`), and it is applied at:
  - thread start (`lib/ravix/tracks.ex:611-617`)
  - sandbox open (`lib/ravix/tracks/sandbox.ex:254-255`)
  - credential-recovery replacements (`lib/ravix/tracks/credential_recovery.ex:69-71`)

  `RuntimeAgents.allow_source/4` adds that set to the agent's allowlist with an
  unserialized GET-then-PATCH (`runtime_agents.ex:155-181`).
- **Where the set id comes from.** It is always read server-side from the
  owner's user row. Nothing takes it from the browser.
- **`Track.payer/2`** (`lib/ravix/tracks/track.ex:129-135`) has no callers yet.

### Allowlist change that admits creator sets

1. **Keep the mechanism:** the payer's set goes in the conversation's
   `inference_credential_id`, and the project/runtime agent's default is never
   changed per prompt (ADR 0009 `:281-282`). For a creator-billed track, the
   payer comes from `Track.payer/2`, and so does the set:
   `Accounts.Store` → `payer.credential_set_id`. `Maintenance.adopt/2` becomes
   payer-aware; it must not keep reading `RuntimeAgents.owner/1`.
2. **Admit creator sets, serialized:** each project/runtime agent's allowlist
   is the sets of payers with creator-billed tracks on that project. Update it
   under one Ravix-side lock per Fountain agent, for example a row lock on the
   `project_runtime_agents`/`projects` row, or `Ravix.Cluster.via/2` on the
   agent id. Inside the lock:
   - `GET` the agent;
   - compute `uniq(current ++ [set])`;
   - `PATCH` the agent;
   - `GET` again and confirm the set is present.

   The lock is Ravix's, because Fountain has no conditional update. Every
   writer of that field must take it, including `Machine.adopt_credentials/2`.
   Today that function overwrites the list with `[]`, which would silently
   evict every creator. It must keep the admitted creator ids and change only
   the default.
3. **Fail closed:**
   - **Launch.** If the set is not confirmed admitted, the launch does not
     happen. Fountain enforces this independently: a set that is not admitted
     is `422 inference_credential_not_allowed`, never a fallback. Treat that
     code as "pause: payer not admitted", not as a credential problem to show
     the owner.
   - **Omitted set.** Omitting `inference_credential_id` is **not** fail-closed:
     it runs on the agent's default, which is the owner's set. For a
     creator-billed track, Ravix must refuse to build a `Launch` whose
     `inference_credential_id` is nil or differs from the payer's set, and
     tests must assert the set sent on every path.
   - **Nil allowlist.** Set `allowed_inference_credential_ids` explicitly on
     runtime agent creation (`[]`, or the admitted list), so no Ravix agent is
     ever left with a nil, open allowlist.
4. **Never from the browser.** The only input is the track id; the set is
   derived server-side from `track.payer_user_id`. The existing
   `Access`/`Store` boundary already holds this. Keep `Launch` construction
   out of `lib/ravix_web/`.
5. **Removal:** a payer's set may stay admitted after their last creator track
   closes. It admits only that payer's own spending, so it is harmless. Prune
   it lazily under the same lock, never in a way that races an admission.

## 2. Source precedence

What Fountain resolves, in order (`lib/fountain/inference_credentials/resolver.ex:21-64`,
documented at `lib/fountain/inference_credentials.ex:926-974`):

1. **The set:**
   - the stored source's `set_id`;
   - else the conversation override;
   - else the agent's `inference_credential_id`;
   - else the account default (`resolver.ex:26-33`).

   A named set that does not exist is `inference_credential_not_found`
   (`:104-106`), never a fallback.
2. **Overrides over the set:**
   - The environment's plain `env_vars`, then environment secrets, then vault
     secrets. The vault wins over the environment (`resolver.ex:266-293`).
   - The merged overrides win over the set's own value for the same kind:
     `Map.merge(own, overrides)` (`resolver.ex:162-170`).
   - Two aliases that disagree within one layer are
     `inference_credential_conflict`.
3. **Kind precedence:** Anthropic prefers `CLAUDE_CODE_OAUTH_TOKEN` over
   `ANTHROPIC_API_KEY`, except on opencode (`resolver.ex:225-227`).
4. **The ChatGPT subscription exception:** a Codex run on a set that names a
   grant runs on the grant or not at all. An `OPENAI_API_KEY` override does
   not outrank it (`resolver.ex:119-123`).
5. **Platform fallback:** only when **no** set was named. When a set is named
   and nothing usable resolves, the result is
   `inference_credential_unusable` (`resolver.ex:108-111`). Ravix always
   names one, so the deployment's keys are unreachable.

The override names are `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`,
`OPENAI_API_KEY` and `GEMINI_API_KEY`, plus the alias
`GOOGLE_GENERATIVE_AI_API_KEY` (`lib/fountain/inference_credentials.ex:647-652`,
`:672-677`).

**Ravix today:**
- **Plain variables:** readable project variables with these names are
  already refused (`lib/ravix/projects/environment_variables.ex:9-12`,
  `:56-59`).
- **Secrets:** a secret with these names is still allowed, as the owner's
  self-billing choice (ADR 0005 `:218-221`). Project secrets are copied into a
  dedicated track's vault (`lib/ravix/tracks/sandbox.ex:197`).

**Required for creator-billed tracks.** A provider-named project secret would
otherwise bill whoever supplied it, not the creator, and the ADR forbids
falling back to the workspace. So the implementation must:
- refuse to open or launch a creator-billed track while the project
  environment or the track vault holds a provider-named secret (tagged
  refusal, visible reason);
- skip no silent copies, and add no Ravix-side rewrite of the vault;
- inventory existing projects by **name only**: `GET …/secrets` returns keys
  and `updated_at`, never values (`lib/ravix/fountain.ex:171-174`), and the
  environment's `env_vars` keys cover variables saved before the Ravix rule.

The alternative, leaving secrets alone because they are the owner's choice,
is not enough. On a creator-billed track, the owner's secret would pay for a
collaborator's prompts, and the collaborator would never see it.

## 3. Converting a live track

> **Superseded by an owner decision (2026-09-28):** existing tracks are not
> converted. Only tracks opened while the switch is on are creator-billed, and
> every other track keeps project-owner billing until it closes. What follows
> still describes how Fountain treats a successor conversation, which is what
> credential recovery relies on: a recovery successor keeps the same payer.

### What Fountain allows

- **No in-place re-bind.**
  - Conversations have no update route (`lib/fountain_web/router.ex:611`); the
    deployed spec has no conversation `PATCH` either.
  - Reapply accepts only `agent_id`, `environment_id`, `vault_id` and `model`,
    and keeps the admitted credential: "a different credential still requires
    a new conversation" (`lib/fountain/conversations/reapply.ex:529-531`).
  - Once a conversation has been admitted, changing its stored set is refused
    at the next turn (§1).
- **A successor starts a new runtime session.** Nothing in Fountain carries a
  Claude session id or a Codex thread into another conversation:
  - A released conversation's successor on the same sandbox "reattaches
    through the ordinary wake path — a new runtime session on the same disk"
    (`lib/fountain/conversations/termination.ex:102-116`).
  - "The runtime session id is left nil on purpose: that is the fresh start"
    (`lib/fountain/team.ex:788-792`).

  The disk (the working tree, uncommitted work) survives. The agent's
  in-context memory does not. Ravix already restores context after a session
  reset with a replayed preamble (`lib/ravix/prompt_queue/recovery.ex`,
  `[ravix: session context restored]`) and uses it for credential-recovery
  replacements (`lib/ravix/tracks/credential_recovery.ex:34-71`).
- **Running turns are never cut.**
  - A prompt during a running turn is `:busy`
    (`lib/fountain/conversations/conversation_server.ex:847-850`).
  - Release refuses a running turn rather than interrupting it
    (`conversation_server.ex:914-919`, `termination.ex:114-115`).
  - A set write does not stop a running turn either: the refusal comes at the
    *next* turn's admission. The one exception is a reconnected or revoked
    ChatGPT grant, whose proxy check can fail a Codex turn midway
    (`decisions/0052-user-owned-chatgpt-grants.md:70-71`).

### Claude

- **No machine lock.** `Binding.bind_inference/2` returns `:ok` for every
  runtime but Codex (`lib/fountain/machines/binding.ex:1050`).
- A new conversation on the **same sandbox** with the creator's set works.

**Conversion plan (Claude):**
1. Skip a thread whose creator *is* the project owner. The set id, and so
   the source, is unchanged, so there is nothing to re-bind: mark the track
   `creator` and move on.
2. Wait for an idle boundary:
   - the Fountain conversation is `idle`;
   - Ravix's prompt queue has no claimed or sent-unconfirmed row for the
     thread;
   - no turn is running.

   A busy thread is left for the next sweep. It is never interrupted.
3. Admit the creator's set on the agent (serialized, §1). Then create the
   successor on the same `sandbox_id`/`vault_id` with the creator's
   `inference_credential_id` and a new channel, reusing `CredentialRecovery`'s
   attempted/created bookkeeping so a crash does not create two successors.
4. Point the thread at the successor. Mark `recovery_context_pending`, so the
   next queued prompt carries the restored-context preamble. Release the old
   conversation (`DELETE` or terminate) only after the successor exists.
5. If the creator has no usable Claude credential (`Inference.usable?`), make
   no successor. Pause the thread with "@creator hasn't connected Claude".
   Nothing falls back to the old conversation's payer.

### Codex

A Codex **sandbox** is bound to one inference source for its life, through
the shared `~/.codex/auth.json`:
- `bind_shared` compares `kind`, `identity` and `revision` with the machine's
  recorded source *and with every Codex conversation it ever carried*, ended
  ones included (`lib/fountain/machines/binding.ex:1105-1136`). A mismatch is
  `409 codex_inference_conflict` (`fallback_controller.ex:341-353`).
- "The sandbox retains its Codex source identity/revision after conversation
  termination or deletion; a different source requires a new sandbox. There
  is no proven reset path that clears this binding"
  (`decisions/0053-inference-credential-sets.md:36-39`,
  `inference_binding.ex:5-10`).
- **The exception:** a set that names a ChatGPT **subscription** gets its own
  `CODEX_HOME` per grant and generation, and does not take the machine's
  binding, *if* the sandbox has `codex_peer_homes`
  (`binding.ex:1076-1086`, `lib/fountain/conversations/codex_chatgpt.ex:275`):
  - A sandbox gets that flag when a Claude conversation built it
    (`lib/fountain/machines/provision.ex:415-441`), or when its first Codex
    bind happened while it was fresh with no recorded source.
  - Machines bound before the column existed keep the old one-source rule.
  - Fountain does not expose `codex_peer_homes` or the bound source over the
    API, so Ravix learns the outcome only from the launch result.

So, for Codex, whether a creator conversation fits on the existing sandbox:

| Sandbox's Codex history | Creator's Codex source | Same sandbox? |
|---|---|---|
| No Codex conversation has ever run on it | anything | **Yes.** The first bind records the creator's source. |
| Only the creator's source (the creator is the owner) | same | **Yes.** Nothing to convert. |
| Owner's source, `codex_peer_homes` machine | ChatGPT subscription | **Yes.** It gets its own home. |
| Owner's API key or grant, on the shared auth file | a different API key | **No:** `codex_inference_conflict` |
| Pre-flag machine with any recorded source | any different source | **No:** `codex_inference_conflict` |

"No" needs a **new sandbox**: `sandbox_mode: ephemeral`, or `DELETE
/api/sandboxes/{id}` to reset the persistent home. Both discard the disk,
including uncommitted work in the track's working tree.

**Conversion plan (Codex):**
1. **The same-source case** is skipped, as for Claude.
2. **At an idle boundary** (as for Claude), try the successor on the **same
   sandbox** with the creator's set. On success, continue as in Claude steps
   3–4, with context restored by preamble.
3. **On `codex_inference_conflict`:**
   - Do **not** reset the sandbox automatically.
   - Leave the old conversation untouched and pause the thread with a
     visible reason, e.g. "Paused: this Codex thread needs a fresh sandbox to
     switch to @creator's account".
   - Offer the creator two ways forward: connect a ChatGPT subscription (which
     fits on a `codex_peer_homes` machine), or explicitly start the thread on
     a fresh sandbox once the track's work is committed or pushed. Ravix can
     show dirty state from Fountain's `git-status` before offering the reset.
   - The old conversation keeps its original payer only while it is paused;
     it takes **no** new turns (there is no fallback).
4. **New creator-billed tracks** never hit the conflict. The creator's source
   is the first Codex bind on their dedicated sandbox.

**Least disruptive path overall:** convert each thread at its next idle point
with a new conversation on the same sandbox, keeping the Ravix-visible
history (Fountain's transcript of the old conversation stays readable) and
restoring context by preamble. Only Codex threads whose sandbox is bound to a
different API-key source cannot convert without a new sandbox. Those pause
for an explicit decision rather than losing a working tree.

## 4. Failure signals

**Refusals at admission** (HTTP errors on create or prompt, and the
`admission_refused` stage event, `lib/fountain/conversations/turn_machine.ex:1304-1326`):

| Code | HTTP | Meaning for the payer |
|---|---|---|
| `chatgpt_grant_unusable` | 409 | The creator's ChatGPT subscription cannot serve Codex. It carries `reason`, `grant_id`, `grant` (name), `until` and `message` (`fallback_controller.ex:156-172`). `reason` is one of `disconnected`, `revoked`, `expired`, `reconnect_required`, `exhausted`, `not_found`, `broker_required` or `owner_ineligible` (`lib/fountain/inference_credentials.ex:835-848`). `until` is set only for `exhausted`. |
| `inference_credential_unusable` | 422 | The creator's set has no credential this runtime can use, i.e. the harness is not connected (`fallback_controller.ex:321-329`). |
| `inference_credential_not_allowed` | 422 | The agent does not admit the set: a Ravix allowlist bug or race. Fail closed and retry after admission. |
| `inference_credential_not_found` | 404 | The set is gone. The payer's account or set was deleted. |
| `inference_source_changed` | 409 | The creator rotated or replaced a key, or reconnected a grant. The pinned conversation is finished, so start a successor under the **same payer** (§3). |
| `codex_inference_conflict` | 409 | The sandbox is bound to another Codex source (§3). |
| `inference_credential_conflict` | 422 | Competing provider-named overrides in one layer (§2). |

**Exhaustion (Codex on a ChatGPT subscription only):**
- **Detection.** A Codex turn failing with a usage-limit hint starts a
  confirmation against OpenAI (`turn_machine.ex:576-592`). That records
  `usage_exhausted_until` from the provider's reset time: the latest
  `reset_at` of the windows at 100%, else `now + reset_after_seconds`, a
  one-hour default, capped at 8 days
  (`lib/fountain/platform_chatgpt/usage_limit.ex:26-49`).
- **Admission.** The next admission is refused as `chatgpt_grant_unusable`
  with `reason: "exhausted"` and `until` (`resolver.ex:205-222`). Nothing else
  in the set is tried: the set's own key, another grant and the platform are
  all excluded (`resolver.ex:119-123`).
- **Clearing.** The value reads as nil once the time passes
  (`lib/fountain/chatgpt_accounts.ex:2475-2477`). Nothing clears it early.
- **Polling.** The value can be read without secrets through
  `GET /api/account/chatgpt-subscriptions` → `exhausted_until`, `status` and
  `revoked_reason` (`lib/fountain_web/controllers/chatgpt_subscription_json.ex:30-38`).
  This list is account-wide, and Ravix is one account. Match the grant the
  creator's set names (`ravix:<user id>`, `lib/ravix/accounts/inference.ex:57`).
  The set JSON itself carries only `chatgpt_grant: {id, name, status}`.
- **Revocation and expiry** of a grant come from refresh failures
  (`codex_chatgpt.ex:172-191`, statuses in
  `lib/fountain/platform_chatgpt/account.ex:89`). A transient refresh failure
  still runs the turn on the current token.

**Claude subscriptions and all API keys have no structured failure.**
- **Storage.** A set stores only ciphertexts and a `revision`. There is no
  status, expiry, quota or `exhausted_until` for them
  (`lib/fountain/inference_credentials/credential.ex:43-59`).
- **What a failure looks like.** A revoked token or an exhausted Claude
  subscription fails the *running turn*. The error is `inspect/1` of the
  runtime error, in a `turn`/`failed` stage event
  (`turn_machine.ex:636-647`, `:720-730`), with no code and no reset time.
- **What Ravix can do:**
  - Show "Paused: @creator's Claude subscription stopped working" with the
    runtime's message, sanitized, whenever a turn on a creator-billed Claude
    thread fails with an auth or quota shaped error.
  - Show "until <time>" only when a reset time can be parsed from that text.
    Never invent one.
  - Pause further turns on that harness for the track, and open the creator's
    Inbox item to reconnect.
  - A quota pause without a known reset time needs a resume trigger: the
    creator reconnecting, or a manual "try again" by the creator.
- **Upstream ask:** a structured Claude auth/quota failure from Fountain (a
  code on the failed turn and, for quota, a reset time) would let "until 3pm"
  be exact.

## Before enabling

> **Dropped by an owner decision (2026-09-28):** these live checks are not
> run before activation. Instead, tests assert the exact
> `inference_credential_id` sent on every creator-billed launch path, and
> that a nil or mismatched one is refused before any request
> (`test/ravix/creator_billing_test.exs`, "every creator-billed launch
> path"). The provider-named value inventory is still required. What follows
> is kept as a record of what a live check would cover.

ADR 0009 phase 1 (`decisions/0009-workspaces.md:435-442`) requires deployed,
not only source, checks. They need Ravix's Fountain account and should use a
**disposable test user's set**, never a real person's set or grant:

1. Admission:
   - A creator set that is not admitted is refused with
     `inference_credential_not_allowed`.
   - After serialized admission, the same launch succeeds, and the turn's
     `inference` reports `origin: own` on that set.
2. A provider-named vault secret on the track vault outranks the set. This
   confirms §2, and that the refusal is needed.
3. A Claude successor on an existing dedicated sandbox under a different set
   succeeds and restores context by preamble.
4. A Codex successor on a sandbox bound to another API-key source returns
   `codex_inference_conflict`. A ChatGPT-subscription set on a
   `codex_peer_homes` sandbox succeeds.
5. Writing the test set yields `inference_source_changed` on the next turn,
   and the recovery successor keeps the same payer.

## Risks

- **An omitted override silently bills the owner.** The agent's own set
  always passes. Every creator-billed launch path must assert the payer's set;
  there is no Fountain-side guard.
- **Allowlist lost updates.** Fountain has no conditional update, and
  `adopt_credentials/2` currently resets the list to `[]`. Every writer must
  share one lock, or creators get evicted and their launches pause.
- **Runtime agents with a nil allowlist** admit any Ravix set today. The launch
  path never names a foreign set, but this contradicts ADR 0009 `:285-286`.
  Close it as part of the implementation.
- **Session loss on conversion.** Every converted thread starts a new runtime
  session. The preamble restores Ravix-visible context, not the agent's
  internal state.
- **Codex API-key tracks may be unconvertible in place.** They pause until the
  creator chooses a subscription or a fresh sandbox.
- **Claude quota has no reset time.** Some pauses cannot say "until".
- **Provider-named secrets** already present on projects block creator-billed
  launches until they are removed. The inventory should run before the owner
  flips `RAVIX_CREATOR_BILLING`.

## Implementation

What Ravix built on this (RAV-17, `Plan-Item: r2-creator-billing`). Every
item below applies only while `RAVIX_CREATOR_BILLING=true`, and only to
dedicated tracks opened while it is on. With the switch off, billing is
exactly what it was.

- **Recording the payer.** `Tracks.open/4` (web, MCP `create_track`, plans
  and schedules all go through it) writes `billing_policy: :creator` and
  `payer_user_id: created_by` in the same insert as the track
  (`Track.creator_billing_changeset/1`). Turning the switch off later leaves
  the row as it is: `Track.payer/2` reads the row, not the switch. There is
  no conversion path.
- **Starting a track.** The opener must have a usable harness of their own,
  or the open is refused with "Connect Claude or Codex to start a track — you
  pay for its agent" (`creator_not_connected`). New track offers only their
  harnesses and the inline connect flow (`ThreadConnect`).
- **Binding (§1).** `Ravix.Tracks.Billing.bind/3` puts the payer's set on
  every create of a creator-billed track:
  - the opening conversation (`Tracks.Sandbox`);
  - every later thread (`Tracks.start_thread/4`), whoever starts it;
  - credential-recovery successors (`CredentialRecovery`).

  `verify/3` refuses a launch whose `inference_credential_id` is nil or
  differs from the payer's set. Queue delivery, retries, wakes and scheduled
  prompts reach Fountain through conversations created on these paths, which
  stay pinned.
- **Allowlist (§1).**
  - `RuntimeAgents.admit_payer/3` runs GET, add, PUT, then GET again to
    confirm, under `Ravix.Cluster.agent_allowlist/2`. That is one `:global`
    lock per Fountain agent, waiting at most five seconds and then failing
    closed.
  - Every allowlist writer takes the same lock, including
    `Machine.adopt_credentials/2`. It still resets the list to `[]` while no
    open track on the project is creator-billed. Otherwise it keeps the list
    and changes only the default.
  - Runtime agents are created with `allowed_inference_credential_ids: []`.
  - `inference_credential_not_allowed` keeps the prompt queued.
- **Provider-named values (§2).** A creator-billed open or launch is refused
  (`provider_secret`, naming the keys, never values) while the project
  environment's variables or secrets, or the vault the track runs with, hold
  one of `EnvironmentVariables.auth_names/0`. `mix ravix.provider_secrets`
  (in a release: `bin/ravix rpc 'Ravix.Release.provider_secrets()'`) lists
  affected projects by name before activation.
- **Pauses (§4).** Pauses are stored per track and runtime in
  `tracks.billing_pauses`.
  - **What pauses a harness:**
    - `chatgpt_grant_unusable`, using its `reason` and `until`;
    - `inference_credential_unusable`;
    - on a Claude subscription or an API key, a failed turn whose reason is
      auth- or quota-shaped.

    The failed-turn check happens once per turn, when the turn is classified
    (`Settlement`), and only within 30 minutes of the failure.
  - **"Until" is shown only for** Fountain's `until` or a time the runtime's
    text carries (`|<unix seconds>` or ISO 8601, at most eight days ahead).
  - **While paused,** queued prompts stay queued with the reason, and new
    threads on that harness are refused with it.
  - **Who sees it:** everyone on the track sees the reason in the composer's
    banner. The creator also gets an Inbox item and "Try again".
  - **A pause lifts when:**
    - the creator reconnects that agent (a newer `credential_connected_at`
      stamp);
    - a reset time passes;
    - the creator presses Try again.
- **Consent and labels.** The creator sees a one-time note the first time
  anyone else can reach the track. It is recorded in
  `tracks.billing_notice_at` when shown. "Paid by @creator" / "Paid by you"
  appears in the track header and beside the model picker. Owner-billed
  tracks show "Paid by @owner" beside the model picker to non-owners.

**Limitations of the implementation:**
- Claude and API-key failures are recognised from Fountain's free-text turn
  failure only. A failure in words the patterns do not know is not paused,
  and some pauses cannot say "until".
- Rotating an OpenAI **API key** on a creator-billed Codex track changes the
  source's revision, so the recovery successor meets
  `codex_inference_conflict` on the same sandbox (§3). This is unchanged from
  owner-billed tracks today. A ChatGPT subscription is not affected.
- There is no live check against the deployed Fountain before activation
  (owner decision). Every dedicated create goes through
  `Billing.create_conversation/4`: it verifies the payer's set immediately
  before the POST, and logs `ravix: creator billing launch track=<id>
  payer=<user id> set=<set id>` for each creator-billed create. That log
  line, and the tests, are the guard.
