# Credential availability

`Inference.usable_agents(user)` returns `{:ok, [:claude, :codex]}` (or the
held subset, in that order). Any supported credential kind makes its agent
usable. This describes credentials held by Fountain, not provider quota or
whether a subscription will accept the next turn.

`Inference.usable?(user, agent)` accepts the agent atom or runtime string and
returns `{:ok, boolean}` or `{:error, reason}`. **Do not use the result directly
as an `if` condition:** both tagged tuples are truthy. Errors are not absence,
and the saved user choice never substitutes for a failed Fountain read.

Both functions accept `fresh: true` to bypass cached and in-flight reads.
The sibling project creation gate should use
`Inference.usable?(owner, effective_runtime, fresh: true)` before provisioning,
propagate provider errors, and map only `{:ok, false}` to `agent_not_connected`.
This change does not add that gate or change project creation.

The five-second cache is per user and credential set. Concurrent misses share
one supervised load. Errors are not cached. Connect, disconnect, and completed
link attempts invalidate even if a later write step fails. Invalidation answers
existing waiters but prevents their result from repopulating the cache. New
readers load a new generation. Each application instance owns a memo; PubSub
propagates invalidation to other instances. During propagation or a cluster
partition another instance can serve an old answer until its short TTL expires;
the creation gate must always bypass the cache. `held/1` remains uncached for
the credential management panel and authoritative reads.

## Existing caller audit

`connected?/1` retains its existing row-only behavior for compatibility. It
answers whether a connection was recorded for the saved choice, not whether
Fountain currently holds something that pays for an agent. The UI migration
belongs to the sibling ravix2 plan; no provider reads have been added to HEEx
render functions here. Load availability asynchronously into assigns, preserve
an explicit error state, and refresh after credential changes.

| Caller | Meaning needed by the follow-up |
| --- | --- |
| `WorkspaceLive.handle_info({:agent_disconnected, ...})` | Availability of the affected projects' runtimes. The saved agent alone cannot establish that every owned project has nothing to run on. At minimum distinguish no usable agents from some, and avoid claiming all projects stopped. |
| `workspace_live.html.heex`, `new-project-no-agent` | Can use the effective runtime selected in the project form; provider errors need separate wording. |
| `OnboardingLive.handle_params/3`, intro skip | Can use at least one agent, regardless of the last saved choice. |
| `onboarding_live.html.heex`, `agent-later` | Can use at least one agent. |
| `onboarding_live.html.heex`, `project-no-agent` | Can use the effective project runtime. |
| `Accounts.finish_onboarding/1`, `ravix.agent_connected` | Currently records saved setup state. If interpreted as ability to pay for `ravix.agent`, use that agent's availability; an unavailable check should be unknown/omitted, not false. Avoid blocking onboarding completion on analytics. |
| `AgentPanel.missing?/2` | Keep the row check: it deliberately compares recorded setup against the independently loaded `held` result. |
| `AgentPanel`, `welcome-connected` | Currently a saved-choice confirmation. If changed to a claim of current availability, use its already loaded held credentials for the selected agent/kind, retaining loading/error states. |
