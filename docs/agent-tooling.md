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
| `projects:write` | Create projects; read/update owned project settings |
| `tracks:read` | Read accessible tracks and transcripts; read this client's tasks |
| `tracks:write` | Create tracks and submit prompts |
| `tracks:cancel` | Cancel this client's queued tasks |

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
| `list_projects` | Optional `after`, `limit` |
| `list_repositories` | Optional `installation_id`, `after`, `limit` |
| `create_project` | `request_id`; `name` for a blank project, or `repo` and `installation_id` |
| `get_project_settings` | `project_id` |
| `update_project_settings` | `project_id`, `settings`, `request_id` |
| `list_tracks` | `project_id`; optional `after`, `limit` |
| `get_track` | `track_id` |
| `create_track` | `project_id`, `request_id`; optional `title`, `origin` |
| `send_prompt` | `track_id`, `prompt`, `request_id` |
| `get_task` | `task_id` |
| `cancel_task` | `task_id` |
| `read_track` | `track_id`; optional integer event cursor `after`, `limit` |

Schemas are discoverable through `tools/list`; the catalog is filtered by scope.
List results carry `items` and `next_cursor`; repository results also carry
installation choices and a `repositories` page. Pages default to 50 items and
are capped at 100. Pass `next_cursor` as `after` to continue. Transcript event
data is capped, with `truncated: true` on oversized events.

Settings allow name, runtime, model, instructions, setup script and packages.
Secret names can be read, but secret values are never returned. Secret writes,
sharing changes, project deletion/rebuild and track closure are not exposed.
Setup scripts and agent instructions can execute code, which the consent page
explicitly explains.

Creation, settings updates and prompt submission require a request ID, at most 100 bytes. Retry with the same
ID and identical arguments to retrieve its receipt. Reusing an ID with different
arguments is rejected. Project/track creation and settings updates claim a
receipt before calling providers. If a process dies during that call, the receipt
reports `operation_unconfirmed` instead of provisioning again. Inspect the
project before deciding to submit a new request ID. Definitive failures also
retain their claim; a corrected operation uses a new ID.

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
