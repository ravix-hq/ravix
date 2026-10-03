# Connect AI tools to Ravix

Ravix serves remote MCP at `/mcp` and A2A 1.0 JSON-RPC at `/a2a`.
Both act as the signed-in person and preserve the browser's owner, project-member,
and track-member permissions. Fountain credentials remain on the server.

The workspace **Help** menu provides setup steps, example prompts, A2A connection
details and troubleshooting. On narrow screens, open **Menu**, then **Help**.

## Claude Code

```sh
claude mcp add --transport http ravix https://app.ravix.sh/mcp
```

Open `/mcp` in Claude Code and authenticate Ravix. The browser opens GitHub sign-in
if needed, then asks whether to grant the client access. Check the client name,
callback destination and scopes. Client names are supplied by the client, not
verified publisher identities. After consent, return to Claude Code.

For example:

> List my Ravix projects, create a track on my app, and ask its agent to fix the
> failing test. Keep the task ID and check its result.

The account dialog links to **Connected applications** at
`/settings/connections`. Disconnecting a client revokes its grant and refresh
credentials. Already accepted work remains queued or running; cancel queued work
explicitly before disconnecting if it should not run.

Claude Code's supported remote connection is MCP. An A2A client can use the second
endpoint directly; native A2A support in Claude Code is not assumed or required.

## Authorization

The endpoints use OAuth authorization code with PKCE S256. Discovery lives at
`/.well-known/oauth-authorization-server` and
`/.well-known/oauth-protected-resource/mcp` (or `/a2a`). Unauthenticated calls
return HTTP 401 with a `WWW-Authenticate` resource-metadata challenge.

Public clients register at `/oauth/register` with `client_name`, `redirect_uris`
and `token_endpoint_auth_method: "none"`. HTTPS redirects and HTTP loopback
redirects are supported; redirects must match the registered URI exactly.
Registration does not grant access. Each browser authorization requires consent.

Send `resource=https://app.ravix.sh/mcp` (or `/a2a`) with authorization, token
exchange and refresh requests. Use `response_type=code`, `code_challenge_method=S256`,
a 43-character SHA-256 base64url challenge, scopes, and a nonempty state value
(up to 256 bytes). Redirect URIs are limited to 512 bytes. `/oauth/token` accepts
form-encoded requests with `grant_type=authorization_code` or `refresh_token`.
Client credentials and browser cookies do not authenticate protocol requests.

Authorization codes expire after five minutes. Access tokens last one hour;
grants last 30 days. Refresh tokens rotate, and reusing a consumed refresh token
revokes the family. Only token hashes are stored. An MCP access token is not
accepted by the A2A resource. The same registered client can obtain separate
grants for both resources. `/oauth/revoke` accepts `token` and `client_id`.

| Scope | Access |
| --- | --- |
| `projects:read` | List accessible projects and repositories |
| `projects:write` | Create projects; read/update owned project settings and preview/run defaults |
| `tracks:read` | Read accessible tracks, transcripts, preview/run configuration, state and logs; read this client's tasks |
| `tracks:write` | Create tracks, submit prompts, configure/start/restart/stop track runs |
| `plans:read` | Read project plans |
| `plans:write` | Create/edit plans and append item notes; assignment also needs `tracks:write` |
| `tracks:cancel` | Cancel this client's queued tasks |
| `workspaces:read` | Read workspace metadata, members, invitations, repository catalogs and personal sidebar organization |
| `workspaces:write` | Create/rename/select workspaces, manage members and connections, admit repository projects, organize personal sections |

Scopes restrict existing membership; they never create membership. A track guest
cannot inspect sibling tracks or change project settings. Grants currently cover
all resources the person can access, including future ones; project-restricted
grants and personal API tokens are not implemented. Revocation and membership
changes are checked on requests and during streaming.

## MCP tools

The server supports MCP versions 2025-03-26, 2025-06-18 and 2025-11-25 over stateless
Streamable HTTP. Ordinary calls return JSON. Server-initiated MCP SSE and MCP
sessions are not used; GET/DELETE `/mcp` return 405. Long work returns a task
receipt, so tool calls do not hold open the connection until an agent finishes.

| Tool | Inputs |
| --- | --- |
| `list_projects` | Optional `after`, `limit`. Each item includes the project owner’s GitHub `owner_login`; `name` stays bare. |
| `list_repositories` | Optional `installation_id`, `after`, `limit` |
| `create_project` | `request_id`; `name` for a blank project, or `repo` and `installation_id` |
| `get_project_settings` | `project_id` |
| `update_project_settings` | `project_id`, `settings`, `request_id` |
| `list_tracks` | `project_id`; optional `after`, `limit`. Each item includes the project owner’s `owner_login` (distinct from the track creator). |
| `get_track` | `track_id` |
| `create_track` | `project_id`, `request_id`; optional `branch_name` (without `ravix/`), `title` (compatibility alias), `origin` |
| `send_prompt` | `track_id`, `prompt`, `request_id` |
| `get_task` | `task_id` |
| `cancel_task` | `task_id` |
| `close_track` | `track_id`, `request_id`; optional `force`, `require_merged` |
| `read_track` | `track_id`; optional integer event cursor `after`, `limit` |

Schemas are discoverable through `tools/list`; the catalog is filtered by scope.
List results carry `items` and `next_cursor`; repository results also carry
installation choices and a `repositories` page. Pages default to 50 items and
are capped at 100. Pass `next_cursor` as `after` to continue. Transcript event
data is capped, with `truncated: true` on oversized events.

Settings allow name, runtime, model, instructions, setup script and packages.
Secret names can be read, but secret values are never returned. Secret writes,
project/track sharing changes and project deletion/rebuild are not exposed.
Setup scripts and agent instructions can execute code, which the consent page
explicitly explains.

Creation, settings updates and prompt submission require a request ID, at most 100 bytes. Retry with the same
ID and identical arguments to retrieve its receipt. Reusing an ID with different
arguments is rejected. Project/track creation and settings updates claim a
receipt before calling providers. If a process dies during that call, the receipt
reports `operation_unconfirmed` instead of provisioning again. Inspect the
project before deciding to submit a new request ID. Definitive failures also
retain their claim; a corrected operation uses a new ID.

## Preview and run tools

These tools manage the existing Sprites service, including plain run scripts with
no HTTP readiness path. They use the same scoped APIs as the browser Run panel.
No tool issues a browser ticket, session grant or provider credential. An ordinary
private preview `url` may appear in state results; view it through a signed-in
browser's Preview action, which still uses session-bound, single-use tickets.

| Tool | Inputs | Scope |
| --- | --- | --- |
| `get_preview_config` | `track_id` | `tracks:read` |
| `preview_status` | `track_id` | `tracks:read` |
| `preview_logs` | `track_id`; optional `limit` (1–4000 characters) | `tracks:read` |
| `update_preview_config` | `track_id`, `request_id`; `config` or `reset: true` | `tracks:write` |
| `run_preview`, `start_preview` | `track_id`, `request_id` | `tracks:write` |
| `restart_preview`, `stop_preview` | `track_id`, `request_id` | `tracks:write` |
| `get_preview_defaults` | `project_id` | `projects:write` |
| `update_preview_defaults` | `project_id`, `request_id`; `config` or `reset: true` | `projects:write` |

A configuration replaces the whole value: required `directory` (relative to the
track root; blank means root) and `command`, with optional `stop_command` and
`readiness_path`. Omit or send a blank optional field to disable it. Commands
execute code on the machine. HTTP apps must honor `$PORT`, bind to `127.0.0.1`
and fail on a port collision. Without a readiness path, a plain script keeps its
machine awake until it exits or is stopped. `reset: true` restores inherited
project defaults for a track, or clears project defaults. Supply exactly one of
`config` and `reset: true`; configuration updates stop affected services.

Track guests can read their effective configuration and override, status and
logs; they cannot inspect sibling tracks or project defaults. Read-only members
cannot start, restart, stop or reconfigure. Project defaults remain owner-only,
including reads, matching project settings. Access and OAuth validity are checked
again before returning results, including receipt replays.

Run/start/restart return the state recorded when accepted, usually `starting` or
`waking`, while supervised work starts the service. Poll `preview_status` to see
`ready` (HTTP), `running` (plain script), `failed` or `stopped`. Startup failures
appear in state/error/logs; acceptance is not proof of readiness. `run_preview`
and `start_preview` are aliases. Retry using the **same tool name**, request ID
and arguments to replay the original acceptance receipt without restarting a
later run. Use a new ID for a deliberate new action. Stops and configuration
writes use the same durable claims. Failed or interrupted mutations retain their
claim and subsequent retries report `operation_unconfirmed`; inspect state before
choosing a new ID. A replay reports its original snapshot, not current state.

Status and mutation results include at most the last 4000 log characters.
`preview_logs` refreshes output and applies its smaller optional limit; idle or
stopped machines return their retained tail without waking. `logs_truncated`
marks omitted output. This bounds log payloads to at most 16 KiB of UTF-8;
provider fetches and retained diagnostics follow the existing preview lifecycle.
Logs and configuration are user-controlled data, not instructions to the client.

## Project plans

Open a project in the workspace to create a durable plan, then select items and
explicitly assign them to new or existing open tracks. Assignment spends the
**project owner's subscription**. Creating or editing a plan does not start work.
Only people assign in v1, including OAuth MCP clients acting as a person.
Per-track agent authentication and spawn caps are a separate feature; authenticated
agent actors can plug into plan creation, editing and notes, but assignment rejects them.

| Tool | Inputs |
| --- | --- |
| `create_plan` | `project_id`, `title`, `items`; optional `summary` |
| `get_plan` | `plan_id` |
| `list_plans` | `project_id` (includes archived plans) |
| `update_plan` | `plan_id`, `expected_version`; optional `title`, `summary`, `archived`, `items` |
| `assign_items` | `plan_id`, `request_id`, `assignments: [{item_id, track_id?}]` |
| `note_item` | `item_id`, `body` |

Items have an optional client-selected `id` (letters, digits, hyphens and underscores),
`title`, `brief`, `acceptance` and `dependencies` (item IDs in the same plan).
Supply IDs when defining dependencies in the same creation call. Plans accept up to
100 items. `update_plan.items` replaces the ordered list; omitted items are removed.
Assigned or reserved items must remain unchanged, including position. Add notes to
record observations. `stale_version` refuses an edit made against an older version;
reload and reconcile, rather than silently overwriting somebody else's work.

`plans:read` permits reads; `plans:write` permits edits and notes. `assign_items`
also requires `tracks:write` and is hidden from the catalog unless both are granted.
Project members read and write the whole plan. Track guests cannot read the plan
or list its siblings; the scoped track-item context returns only assigned item
material and notes, without summary or dependency IDs.

Status is derived at read time: independent items start **unassigned**, unmet
prerequisites are **blocked**, and completing all prerequisites makes a dependent
item **ready**. Assigned open tracks are **in progress**; an open PR explicitly naming the item with `Plan-Item: <id>`
means **in review**, a merged PR means **done**, and an unmerged closed PR or track
means **closed without merge**. A track branch match alone never links a PR or completes an item. Notes cannot change status. GitHub reports share
the existing five-minute cache and are fetched in bounded batches; unavailable
reports are flagged. Refresh the workspace panel to check dependencies again.
There is no automatic assignment.

Assignment first commits a mutation claim and item reservations, opens all tracks,
then queues prompts containing the plan rationale, acceptance notes and sibling
scope with assigned track IDs. The prompts require scope discipline, rebasing,
pushing and a draft PR, and forbid merging. Existing tracks keep their original
origin. Each successful result includes `item_id`, `track_id` and a task receipt.
Retry the same request ID and arguments to retrieve the same results. Partial
failures return per-item `assignment_unconfirmed` or `prompt_unconfirmed`; inspect
those tracks before starting more work. A crash between acceptance and receipt
completion returns `operation_unconfirmed`, and reservations prevent duplicate
provisioning. There is no automatic release of ambiguous reservations in v1.

## A2A

Discover `/.well-known/agent-card.json`. It declares A2A 1.0 over JSON-RPC 2.0, OAuth, text
input/output, streaming, and the optional Ravix routing extension
`https://ravix.sh/a2a/extensions/tracks/v1`.

A context ID is an existing Ravix track ID. Each submitted message starts one
new task in that context. A task is not the track: completing a task does not
close the track. Existing tasks do not accept follow-up messages; send a new
message ID in the same context. Include `A2A-Version: 1.0` on requests.

```json
{
  "jsonrpc": "2.0",
  "id": "rpc-1",
  "method": "SendMessage",
  "params": {
    "message": {
      "messageId": "desktop-request-1",
      "role": "ROLE_USER",
      "contextId": "YOUR_TRACK_ID",
      "parts": [{"text": "Fix the failing parser test."}]
    },
    "configuration": {"returnImmediately": true}
  }
}
```

The result contains `task`, with `id`, `contextId`, `status` and reply artifacts.
To open a new track instead, omit `contextId` and set
`params.metadata.ravix.projectId` to an accessible project ID. The message ID
deduplicates track creation and prompt submission. Project administration is
available through the typed MCP tools; A2A does not turn arbitrary messages into
project-settings changes.

Supported methods are `SendMessage`, `SendStreamingMessage`, `GetTask`,
`ListTasks`, `CancelTask` and `SubscribeToTask`. `ListTasks` supports context/state,
status-timestamp filters, bounded page size, cursor pagination, and optional
artifacts. Tasks are visible only to their initiating user and registered client,
subject to current track membership. Reconnect with a fresh token for that same
client, not a newly registered client ID.

`SendMessage` blocks by default; `returnImmediately: true` returns after durable
acceptance. Blocking HTTP waits time out after about 55 seconds without canceling
work; the error includes the task ID to poll. Streaming returns an initial task
snapshot followed by status/artifact updates. Streams also rotate after about
55 seconds; reconnect with `SubscribeToTask`, or use `GetTask` if already terminal.
Subscriptions replay the persisted snapshot, not individual event IDs. No push
notification callbacks or authenticated extended agent card are advertised.

Task reads and streams reconcile the provider's turn carrying the exact
`client_request_id` used by Ravix's prompt queue. Delivery is not completion;
other users' and autonomous turns cannot complete the task. `ListTasks` reports
persisted observations; use `GetTask` to refresh a task's execution state. A read
advances at most one 100-event provider page, so long transcripts may require
several polls before the terminal result is reached. Reply artifacts retain up
to 64,000 characters of agent text. Tasks and mutation receipts persist across
HTTP disconnects and application instance changes.

Only queued work is cancelable. Fountain's interrupt operates on a conversation,
so using it to cancel a task could interrupt somebody else's next prompt.
Running/terminal tasks return `TaskNotCancelableError`; canceling an already
canceled task is idempotent. Closing a connection never cancels accepted work.

## Verification

Context and HTTP tests cover PKCE, single-use codes, token rotation/replay,
resource audiences, scopes, current membership, mutation receipts, correlated
completion, paging, and stream revocation. `browser/tooling.spec.js` exercises
real GitHub-mock sign-in and consent, MCP project/track creation, A2A submission,
refresh/reconnection, completion and disconnect in the production-mode browser
harness. Provider behavior is mocked there; it is not a claim of testing a live
customer subscription or an interactive Claude Code session.

References: [MCP authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization),
[A2A specification](https://a2a-protocol.org/latest/specification/), and
[Claude Code MCP](https://code.claude.com/docs/en/mcp). Reviewed 2026-09-22.

### Naming a track

`create_track` accepts `branch_name` and the published compatibility alias `title`.
If both are supplied, `branch_name` wins. Omit the name or send an empty string
for a generated name. Names use the same Git branch validation as the web form;
new branches are `ravix/<name>`. PR origins retain the existing head branch and
ignore the supplied name. The alias has no scheduled removal.

`origin` is optional and accepts `{"kind":"blank"}`,
`{"kind":"branch","base":"release"}`,
`{"kind":"pr","base":"feature/fix","number":42}`, or
`{"kind":"issue","number":42,"title":"Fix login","base":"main"}`.
Omitting it starts a blank track. `base`, `number` and `title` are optional;
base defaults to the project's default branch.

MCP tool failures include `structuredContent.error` with `code` and `message`.
Invalid or unavailable names also include `field` (`branch_name` or `title`)
and the same validation message as the web form. Retry a mutation with the same
`request_id` and unchanged arguments to retrieve its original receipt.

### Stored task state

Task receipts advance on queue changes and a followed thread's turn settlement,
without requiring `get_task`. A cluster singleton also reconciles tasks older
than their reconciliation interval every five seconds, rotating through at most
50 threads per pass with four concurrent provider reads and a 30-second timeout
per thread. Every attempt records `reconciled_at` without changing the receipt's
status timestamp; older receipts fall back to `updated_at`. WORKING receipts
with a known turn and a sent queue row use 45 seconds; other pending receipts
use three seconds, including sent SUBMITTED receipts and queue-state mismatches.
Queue and settle hints bypass this cadence and reconcile immediately.
The database is authoritative; a replacement singleton rebuilds its subscriptions
and sweep position from it. Brief singleton overlap is harmless because receipt
writes lock and recheck queue state, terminal state and the event cursor.

Each reconciliation fetches turns once per thread and shares event pages across
its tasks, stopping each reply at its turn's boundary. Earlier pages may still
be needed to locate that window; later unrelated output is not traversed.
Persisted task notifications wake waits without triggering another provider read.

`wait_task` with `timeout_ms: 0` returns persisted terminal or held states without
Fountain requests. Other snapshots still attempt a refresh within 250 ms. `stale`
is true when that budget expires with active tasks still unreconciled, or an
external event arrives during the refresh. It is false for wholly terminal or
held snapshots. Missing events and provider outages can delay persistence until
a successful backstop pass; `stale: false` is not a provider freshness timestamp.
All reads still require the submitting principal and OAuth client.

### Closing a track

`close_track` (`tracks:write`) closes a track the way Close in the browser does,
with the browser's rule: the project owner or the track's creator, and only its
creator for a private track. Anybody else who can see the track gets
`forbidden`; anybody who cannot gets `not_found`. It is irreversible: the
machine or worktree is discarded and the track's unsent prompts are cancelled.

Without `force: true` it refuses a track with a running turn on any thread
(`track_running`), with queued or sending prompts (`prompts_queued`), or whose
running state Fountain cannot report (`status_unavailable`). On a shared
machine `force` also removes the worktree with its uncommitted changes.
`require_merged: true` refuses unless the track's pull request is merged
(`pr_not_merged`), reading GitHub past its five-minute cache. The pull request
is read before the running and queue checks, which come last before the close. A successful close returns `{"closed": true, "pr": {"number":
218, "state": "merged"}}`; `state` is `merged`, `open`, `closed`, `none` or
`unknown` (GitHub could not be read, which `require_merged` treats as not
merged). A refusal releases its `request_id`; retrying a completed close with
the same ID returns the original result even after the creator loses access.

### Setup recovery and PR origins

Call `retry_setup` with `track_id` to run the browser's scoped Retry setup action
(`tracks:write`). Wait for setup to succeed, then call `retry_task` with the
failed saved prompt's `task_id`; setup retry does not resend that prompt.
MCP task presentation names both tools for failed queued prompts while their track setup is failed; browser messages retain human recovery guidance. The queue preserves the specific provider or sandbox error code, falling back to `setup_failed` only when no specific code is available. Once setup recovers, MCP no longer asks callers to retry setup.

`assign_items` accepts a new `request_id` for an item whose track has failed setup
or is closed, including closure during a machine rebuild. Omit `track_id` to open
a replacement track. Live tracks still return `item_assigned`; replaying the old
request ID returns its original receipt.

For `create_track`, an origin such as `{"kind":"pr","number":261}` resolves the
head branch from GitHub before provisioning. A lookup failure returns an error;
it never falls back to `main`. Fork heads are refused because their branches are not in the project repository. The browser's explicit `origin.base` remains
supported for an already selected PR head.

## Workspace administration

Workspace tools require explicit `workspaces:read` or `workspaces:write` consent.
Existing grants keep their scopes, including after refresh; reconnect with new
consent to add workspace permissions. Scopes never override role or membership
checks. Tokens and provider credentials are never returned. Workspace invitations
use GitHub logins and become memberships at sign-in; they have no invite secrets
or links to reveal.

| Operations | Tools and requirements |
| --- | --- |
| Metadata | `list_workspaces`, `get_workspace` (read); returns your role and `access_enabled` |
| Workspace management | `create_workspace` (any signed-in person), `update_workspace` (owner/admin rename), `select_workspace` (save your sidebar choice) |
| People | `list_workspace_members`, `list_workspace_invitations` (read, any member); `invite_workspace_member`, `revoke_workspace_invitation`, `remove_workspace_member` (owner/admin); `set_workspace_member_role` (owner); `leave_workspace` (self) |
| Repository catalog | `list_workspace_connections`, `list_workspace_repositories` (read, cached); `refresh_workspace_repositories` (write, any member) |
| Connections | `list_available_workspace_installations` (read, owner); `add_workspace_installation` (write, owner, rechecks your GitHub authority); `get_workspace_connect_url`, `get_workspace_configure_url` (write, owner/admin) |
| Repository admission | `add_workspace_repository` (write); owner/admin may create a project using the existing provisioning/payer rules; any member may retrieve an existing canonical project |
| Personal sidebar | `list_workspace_sections`, `list_workspace_placements` (read); `create_workspace_section`, `update_workspace_section`, `delete_workspace_section`, `move_workspace_placement` (write, any member, only your sections) |

Except `list_workspaces` and `create_workspace`, tools require `workspace_id`.
Creation takes `name`; update renames with `name`. Membership targets use `user_id`,
invitations use `login`, and roles are `owner`, `admin`, or `member`. Only owners
may grant elevated roles or withdraw protected invitations. The last owner cannot
leave, be removed, or be demoted. Workspace deletion is not exposed.

All mutations require `request_id` and follow the existing durable receipt
convention. Retry identical arguments with the same ID. Authorization is checked
again on every replay; removed members cannot retrieve old workspace receipts.
For completed section deletion the caller's own receipt remains replayable while
they still have workspace access. Local refusals release their claim. Repository
refresh, installation binding, and repository admission retain claims on failure
or uncertainty; inspect the outcome before choosing a new ID.

Lists accept `after` and `limit` (default 50, maximum 100) and return `items` and
`next_cursor`. Each list has its own cursor. Refresh reports independently bound
failed installation IDs, renamed repositories and collisions to 100 entries,
with `truncated` for each report; raw provider errors are not returned. Listings
paginate the existing context snapshots in memory, not the underlying database
or GitHub fetch. Refresh still reads the provider's complete catalog.

`RAVIX_WORKSPACE_ACCESS` gates administration, repository tools, and scoped sidebar
organization. Metadata remains readable with the switch off, and removing members
or leaving remains allowed as in the browser's contexts. Workspace membership
then grants no project access. Repository tools never substitute a personal token
for a workspace installation. `add_workspace_installation` instead uses the
existing owner-only proof of visibility with the owner's sign-in token.

`get_workspace_connect_url` returns `/w/:workspace_id/github/connect` on the
public Ravix host. Open it in a browser signed in as the same person. That existing
route rechecks the session, role and flag and mints short-lived state bound to the
browser session, workspace and user; the callback consumes it once and requires
GitHub's authorization code. An MCP bearer token cannot complete that round trip.
The configure URL connects nothing on return; refresh afterward.

Section edits take `section_id`, optional `name` and `collapsed`. Placement edits
take `project_id` and `section_id`; an empty section ID clears the placement. Both
section and project must belong to the caller's sidebar workspace. These edits
change personal organization only. Other people's sections and inaccessible
project IDs are refused; stale inaccessible placements are omitted from reads.
