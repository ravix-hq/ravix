---
type: ADR
title: "Track agents use project-scoped Ravix tooling as the person who prompted them"
description: "Proposes short-lived track grants, durable delegation limits and attribution; implementation waits for isolated turn credentials on shared machines or the sandbox-per-track design. Fountain already supports agent MCP registration and brokered header rotation."
tags: [architecture, agents, authorization, fountain]
status: draft
adr: "0007"
adr_status: "Proposed"
date: 2026-09-22
generated: { by: process:codex, at: 2026-09-22T00:00:00Z }
stale_after: 2026-10-22
---

# 0007 — Track agents use Ravix tooling

**Status:** Proposed; investigation and design only. No grants, migration,
registration, limits or prompt changes are implemented by this ADR. Fountain
can carry MCP configuration, but its current shared-machine contract cannot
isolate the required per-track, per-person credential. Do not enable a shared
project credential as an interim implementation. Number 0006 is reserved by
[the sandbox-per-track ADR](0006-a-sandbox-per-track.md), merged as a proposal
while this investigation was running.

## Context and investigation

Ravix already serves the tools documented in `docs/agent-tooling.md`.
Its OAuth flow requires browser consent and its grants are not project-scoped.
A track agent needs to delegate without browser authentication and without
inheriting every project its human can access. Every child spends the project
owner's subscription, as [ADR 0005](0005-each-person-brings-their-own-agent.md)
requires; the person authorizing work and the person paying can differ.

Inspected Ravix's `Fountain` client, `Fountain.Shapes.Catalog`,
`Fountain.Launch`, `Spec`, `Projects.Machine`, prompt delivery, Tooling and the
Bun mock. Inspected upstream Fountain main at commit
`530f058734ee65f6223208a4753a888fe20df9eb` on 2026-09-22. These are source and
API-contract findings, not a live runtime verification:

| Surface | What actually exists |
| --- | --- |
| Agent | Create/update accepts `mcp_servers`, a map keyed by server name; an HTTP entry has `type`, `url` and `headers`. This is where registration belongs. |
| Catalog | `mcp_servers` is a list of suggested verified remote servers, **not an allowlist or a registration API**. Ravix dropping this catalog field does not prevent registering Ravix. |
| Environment and vault | Environment variables plus environment secrets and vault secrets feed recursive `${VAR}` substitution; vault wins. The vault is selected per conversation, subject to the agent's allowlist. |
| Runtime session | `McpServers.substitute_agent/3` resolves configuration on provision/reattach/wake. `for_session/3` passes that resolved configuration to ACP `session/new`. Re-reading an agent before a turn does not freshly substitute its header from the vault. |
| Broker | A bound secret becomes a placeholder before MCP substitution. `Egress.refresh_before_turn/1` re-reads tenant secrets and updates live conversation broker rules before turns; no new runtime header value is required for a rotated bearer. An unbound vault secret enters the sandbox in cleartext. |
| Launch/prompt | `ConversationCreateRequest` selects agent/environment/vault; it has no MCP or turn-secret override. `PromptRequest` carries prompt, images and request ID, not credentials. |
| Shared disk | Attach requires the same agent/environment/vault identity. A separate vault cannot be attached to the existing project machine. Configuration reapply changes the machine identity and rewrites its MCP configuration; it is not a private per-track override. |

Evidence: Fountain's [schemas][schemas], [MCP session assembly][mcp],
[egress rotation][egress], [launch and attach][launch],
[vault semantics][vault], [secret bindings][secrets] and
[remote MCP guide][remote]. The [reapply API][api] explicitly says that the
machine also takes the new identity. A `connection` entry is a separate OAuth
connection mechanism; it does not mint a Ravix delegated grant.

The Bun mock returns `mcp_servers: []` in its catalog, accepts arbitrary fields
on agents, and checks the attach identity. It neither starts a real MCP client
nor implements substitution or the egress broker. A successful mock update
would prove JSON transport only, not credential isolation or rotation.

`Projects.Machine.refresh_clone_token/2` supplies the rotation pattern:
mint through GitHub, then `Fountain.put_secret(client, :vaults, vault_id,
key, token)` before machine work, with errors propagated. Initial provisioning,
track opening/reattaching and queued turns pass through preparation. The
broker's before-turn re-read explains why updating the vault repairs an
already-running conversation. A GitHub installation token is project-wide;
copying that **scope** for Ravix would be incorrect. Tooling preparation must
also know the claimed queue row, sender, source track and generation.

## Decision

### Identity and authority

Act as the person whose durable prompt row starts the running turn. Use a
persisted creator user ID only for a system opening turn that has no human
sender; `created_by_login` alone is not an identity. Never fall back to the
creator when a known sender has lost access. Descendants inherit the prompting
person through delegated task/queue records, not the project owner.

Shared-track turns require a new authorization generation when the sender
changes. The prior generation must stop authorizing requests before the next
person's turn begins. This is a binding to a turn, not a mutable “current user”
that an old worker can inherit. Do not expose a new person's grant to an old
runtime or background process. A persisted agent transcript may contain older
information; scoped tokens cannot erase that history or establish a sandbox
security boundary.

Authority is the intersection of the named person's **current** access, the
grant's single project, and its scopes. Exactly `tracks:read`, `tracks:write`
and `tracks:cancel`; no `projects:write`, `projects:read` or project settings.
Provide the project ID directly in trusted turn configuration, so an agent does
not need `list_projects` to find it. Every tool path must enforce the restriction,
including a track ID, a task ID, pagination, receipt replay and A2A entry points.
The token audience is only Ravix's `/mcp`; A2A must reject it.

A track share grants no project membership. A guest's agent may operate only
on the shared track, subject to existing task ownership restrictions. It cannot
open children, list siblings or prompt an unshared sibling. A project member
may delegate inside that project. Losing project membership invalidates that
project-member grant even if a separate track share remains; a later guest
turn may receive a new, narrower grant. Losing the source track share revokes
a guest grant. No upgrade happens merely because a stronger human next uses
the same track.

### Credential lifecycle

Reuse `tooling_grants` and `tooling_credentials`, the existing hash primitive,
expiry and revocation checks, and `Ravix.Tooling`'s `Accounts.Access` doors.
Add nullable grant attributes for kind, source track, project, access basis
and turn generation with an expand-only migration. Existing interactive grants
retain their behavior. Use a stable internal client identity per source track
so tasks remain addressable after rotation, still partitioned by user; do not
make those clients publicly registerable or allow browser consent to widen them.

Mint a random bearer server-side after authorization, lasting one hour. Store
only its hash in Ravix; there is no agent refresh token. Fountain's write-only
encrypted vault necessarily holds the bearer for brokerage. Do not store it
in agent JSON, environment variables, prompts, receipts, telemetry, logs,
LiveView assigns or transcripts. Raw values exist briefly only in the mint/write
path; request authentication should retain a hash-backed principal instead of
the current `OAuth.authenticate/2` map's raw `token` field.

Before each claimed turn, revoke the previous generation, mint the replacement,
write it into the isolated vault and confirm delivery/configuration before
sending the prompt. Vault-write failure revokes the candidate and holds the
turn. Retry mints another token, never recovers plaintext from storage. A crash
after a vault write leaves at most a short-lived unusable generation until the
durable preparation finishes; a stale writer must not overwrite a newer
generation. The server remains the authority even if vault cleanup fails.

Closing the source track or removing the applicable membership revokes grants
and credentials transactionally. Authentication and Tooling rechecks also read
source-track closure, membership, expiry and generation, so a missed cleanup or
another instance's stale state cannot preserve access. Reopening never revives
an old token. Revoke at turn completion as well; a long-running turn whose
hour expires must fail closed and wait for renewed authorized work. Automatic
mid-turn renewal is outside the first slice.

### Limits, billing and attribution

Initial server-enforced defaults (team may tune before acceptance): root depth
0, maximum child depth 3; at most 5 child openings over a source track's lifetime;
at most 20 accepted delegated prompts in a rolling 10-minute window per source
track. Count across users, token rotations, runtime sessions and instances.
Closing children does not refund capacity. Reserve an opening before provider
work and retain ambiguous reservations; idempotent retries of the same request
do not consume capacity again. Rejected preflight authorization consumes none.
New request IDs cannot evade the quota. Read/poll operations do not spend prompt
capacity. A project-wide budget is an additional open question, since different
human-created roots otherwise multiply the allowed spend.

Return predictable tagged errors through the existing RPC error mapping:
`{:error, {:conflict, "track_spawn_depth_exceeded", message}}`,
`{:error, {:conflict, "track_spawn_limit_exceeded", message}}`, and
`{:error, {:conflict, "track_prompt_rate_exceeded", message}}` (the last message
includes when to retry). Check access before exposing quota information.

Add nullable `parent_track_id` foreign keys to tracks and tooling tasks,
plus durable person and originating grant/generation attribution for delegated
work. For a task, the parent is the calling source track, distinct from its
target `track_id`. Derive all attribution from the authenticated grant, never
from tool arguments. Store child depth and reservation counts durably, enforce
same-project ancestry and acyclic creation, and index the foreign keys. Existing
rows remain roots; never infer a parent from a branch name or prompt text.

The rail shows **“opened by <track> for <person>”**, with escaped labels and a
parent link only if the viewer currently has access. Guests must not learn an
unshared parent's title through attribution: use a neutral “another track”
label in that case. Keep attribution after the parent closes. Make the owner's
subscription cost explicit at the delegation entry point. Attribution does not
add membership to either track.

### Multiple instances and in-flight revocation

Follow [ADR 0003](0003-cluster-and-transparent-deploys.md): the database owns
authorization generations, quota reservations, ancestry and idempotency.
Reserve quota and the existing mutation receipt in one transaction under a
source-track row lock; prompt acceptance and its quota debit are atomic too.
No ETS counter or node-local rate limiter decides whether delegation is allowed.
Keep external calls outside those transactions, with durable pending/confirmed
states and the existing `operation_unconfirmed` outcome on ambiguous failure.

A cluster-named per-track coordinator can serialize preparation but is not a
replacement for database fencing. The vault handoff needs an acknowledged
generation/CAS contract so a delayed write from a failed instance cannot replace
the newest credential. A losing writer's bearer must always be invalid in Ravix,
and retry must reconcile the vault before releasing the prompt. Rolling deploys
add columns before readers; enable minting only once all serving instances
understand the restrictions. Old servers must never treat these as unrestricted
interactive grants.

Revocation rejects subsequent calls, receipt reads and stream updates. Recheck
the originating grant and current membership when dispatching accepted delegated
queue work; cancel still-queued tasks when their authorization is gone. This is
stricter than existing interactive OAuth disconnect, which leaves accepted work
queued. Preserve the queue's durable sender and add origin-grant metadata.

An already accepted provider mutation may finish after revocation; a response
recheck cannot undo it. Keep its receipt and attribution for authorized human
review. A running turn cannot be canceled safely through today's task-specific
API: Fountain interrupts conversations, which might now belong to another
prompt. Do not interrupt unrelated work. Children already opened remain real
tracks; closing a parent does not recursively destroy their work. Revoke that
parent's ability to send more prompts, and apply each child's own grant checks.

## Provider blocker and path to implementation

Registration syntax itself is supported today, for example this **uninstalled**
template (the placeholder is not a credential):

```json
{"mcp_servers":{"ravix":{"type":"http","url":"https://app.ravix.sh/mcp","headers":{"Authorization":"Bearer ${RAVIX_TOOLING_TOKEN}"}}}}
```

It additionally needs an enabled secret binding for `RAVIX_TOOLING_TOKEN` to
the exact configured Ravix HTTPS host. Without a binding/broker, fail closed;
never fall back to a plaintext header. Config URLs come from trusted server
configuration, not a tool caller. Catalog discovery is unnecessary.

**What Fountain needs for Ravix's current shared machine:**

1. A conversation/turn-scoped MCP and secret overlay, separate from persistent
   sandbox identity and the shared agent/environment/project vault. Attach and
   prompt must select the overlay without rewriting another track's files.
2. A broker binding to an authorized turn generation, with an acknowledged,
   idempotent or conditional vault update/activation. Rotation must affect the
   intended runtime (including a reused ACP peer), reject stale writers and
   fail the turn if activation fails. Closure/revocation must disable old
   generations without handing the next person's authority to an old process.
3. An isolation guarantee: a sibling or previous sender's process on the shared
   machine cannot read or reuse another turn's broker/callback credentials.
   Merely adding a header override is insufficient on a shared OS identity.
   Alternatively, require isolated sandboxes instead of promising this property.
4. Capability/version reporting and Claude/Codex integration tests showing that
   only the selected turn receives the server and its current credential, with
   secret redaction on errors, reconnect and rotation. Account-wide OAuth
   connections are not a substitute for Ravix's delegated identity.

**Alternative without a new generic MCP registration feature:** land and verify
the [sandbox-per-track design](0006-a-sandbox-per-track.md), then give each track an isolated vault
and runtime configuration using existing agent MCP registration and custom
secret bindings. That is a larger lifecycle change than this slice and belongs
with ADR 0006. It still needs safe handoff between people on a shared track,
fenced rotation and proof that an old process cannot use a later sender's
authorization. A fresh isolated runtime/security context per sender may be
necessary. Do not silently treat a worktree as a credential boundary.

Once one path meets the contract, ship grants/rotation/revocation, the expand-only
ancestry migration, durable caps, filtered rail attribution and registration
together. Add this short system-prompt section only when the capability is
actually available, with the bound project ID supplied separately:

> Ravix tooling lets you list, open and prompt tracks in this project, within
> the prompting person's access. Delegate only the requested work and respect
> delegation limits; child turns spend the project owner's subscription.
> Keep each task ID and poll get_task until terminal: delivery is not completion.
> Track guests can work only in their shared tracks and cannot open siblings.

## Validation required before enabling

Use the repository's ravix-elixir and ravix-testing skills, real persisted users,
projects and grants, and provider-boundary stubs. Add context and HTTP tests for:

- A member of two projects cannot use a token bound to one against the other,
  including indirect task IDs, receipt replay, transcripts and A2A audience.
- A guest cannot see/list/prompt siblings or open children; a shared track does
  not grant the project. Changing senders never inherits the creator's access.
- Removed membership, source closure, expiry, superseded generations and revoked
  grants reject requests, queued dispatch and streaming; rejoin/reopen does not
  revive old credentials. Provider work accepted before revocation is accounted for.
- Concurrent callers on separate BEAM instances cannot exceed depth/count/window
  caps, and idempotent retries neither duplicate side effects nor spend twice.
- Crash/retry and late vault writes fail closed. Both runtimes use the rotated
  credential without retaining a previous sender's authority; cross-track and
  old-process attempts fail at the actual broker boundary.
- Sentinel token values never reach captured logs/telemetry, assigns, outbound
  prompt bodies, MCP config files, stored receipts or transcripts, including
  provider failures and malicious echoed headers. Mock JSON storage alone is
  insufficient evidence for this property.

Run focused tests, `mix precommit`, and browser checks for the rail change;
verify live broker/runtime behavior separately before calling it shipped.
This documentation-only change does not claim those new regression tests exist.

## Open questions and consequences

- Accept the prompting-person identity and creator fallback only for system
  opening turns? How should unattended scheduled work name its authorizer?
- Accept the proposed limits and one-hour lifetime? Should the project owner
  explicitly enable delegation or set a project-wide spend ceiling?
- Is queued cancellation on delegated-grant revocation the desired behavior,
  and should parent closure separately offer cancellation of descendants?
- Which path owns the isolation prerequisite: Fountain turn credentials or
  ADR 0006 plus per-sender isolation? Confirm the deployed broker capability,
  secret-binding feature flag and runtime support before implementation.
- On a machine that serializes turns, a parent polling a queued child can hold
  the very slot that child needs. Verify scheduling/yield behavior or use separate
  sandboxes; polling must not become an unbounded spend loop.
- Should queued descendant work retain the original grant, or a separately
  approved durable delegation? This proposal retains it and fails on revocation.

The feature remains unavailable until that boundary is real. It needs no public
personal-token UI, OAuth bypass endpoint, account-wide connection or wider
project administration scope. Existing interactive MCP clients are unaffected.

## Alternatives considered

- **One owner token in the project vault:** gives guests the owner's authority
  and lets siblings impersonate one another; rejected.
- **Rotate one shared token before each turn:** refresh reaches multiple
  conversation brokers and old processes; serialization alone is not isolation.
- **A new vault per track on the existing disk:** violates Fountain's attach
  identity; reapply mutates the shared disk rather than solving the boundary.
- **A unique secret key per track in the shared vault:** every attached process
  receives the same merged secret set; naming is not access control.
- **Put a bearer in the prompt or ask the agent to finish OAuth:** leaks a
  credential or requires interactive browser consent; rejected.

[schemas]: https://github.com/BinaryBourbon/fountain/blob/530f058734ee65f6223208a4753a888fe20df9eb/apps/fountain/lib/fountain_web/schemas.ex
[mcp]: https://github.com/BinaryBourbon/fountain/blob/530f058734ee65f6223208a4753a888fe20df9eb/apps/fountain/lib/fountain/conversations/mcp_servers.ex
[egress]: https://github.com/BinaryBourbon/fountain/blob/530f058734ee65f6223208a4753a888fe20df9eb/apps/fountain/lib/fountain/conversations/egress.ex
[launch]: https://github.com/BinaryBourbon/fountain/blob/530f058734ee65f6223208a4753a888fe20df9eb/apps/fountain/lib/fountain/conversations/launch.ex
[vault]: https://github.com/BinaryBourbon/fountain/blob/530f058734ee65f6223208a4753a888fe20df9eb/docs/concepts/vault.md
[secrets]: https://github.com/BinaryBourbon/fountain/blob/530f058734ee65f6223208a4753a888fe20df9eb/docs/concepts/secrets.md
[remote]: https://github.com/BinaryBourbon/fountain/blob/530f058734ee65f6223208a4753a888fe20df9eb/docs/guides/connect/remote-mcp-server.md
[api]: https://github.com/BinaryBourbon/fountain/blob/530f058734ee65f6223208a4753a888fe20df9eb/docs/api.md
