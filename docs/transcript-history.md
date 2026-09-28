# Transcript history (RAV-28)

Opening a thread renders the newest ten complete turn groups in its current
conversation. Load earlier prepends another group without re-parsing the visible
tail. Interleaved turns stay together, so a chunk may exceed ten turns. A single
large turn is never truncated. Older conversation IDs are visited newest first,
only when the current conversation's earlier chunks have been exhausted.

The live cursor remains `Page.last_event_id`, in the current conversation.
`oldest_conversation_id` and `oldest_event_id` identify the loaded history edge.
Access is checked again for each earlier read and each LiveView async result.
LiveView inserts only the earlier turns at the beginning of its stream; the
browser anchors the first visible article across the patch, including when live
output arrives below it. Late catch-up results retain already loaded history.

## Provider limitation

Inspected Fountain main `f941a837616eb48f20f144c265d34122e77206d9`:

- `apps/fountain/lib/fountain_web/controllers/conversation_controller.ex`:
  events supports ascending `after`, `limit` (100 default, 1,000 maximum),
  `streams`, `blocks`, and `prompts`. No `before`, reverse order or turn filter.
  The controller's `before` parameter belongs to **egress**, not events.
- `apps/fountain/lib/fountain_web/schemas.ex` and `conversation_json.ex`:
  `/turns` returns all turn metadata, prompts and image counts, with no event
  cursors. Conversation detail also has no tail event cursor. There is no
  turn-scoped event endpoint.

Requested backward/turn-scoped reads in
[managoat/fountain#2531](https://github.com/managoat/fountain/issues/2531).

Until that exists, the fallback still scans **all event pages of the current
conversation** before rendering its newest turns. It retains earlier raw events
in per-page chunks, partitioned once, to avoid another network scan on prepend.
This improves rendering and defers older conversations, but does **not** solve the
initial provider latency or bound memory by the visible window. The 7,000-event
fake-transport regression explicitly records seven requests with today's API;
claiming one or two would misrepresent the provider contract. No arithmetic on
global/sparse event IDs is used to guess a tail cursor.

`tracks.events` records `ravix.event_pages`, `ravix.events_fetched`, and the
rendered chunk's `ravix.event_count` and `ravix.turn_count`. Earlier reads have
their own `tracks.events.earlier` span; retained chunks report zero provider
pages/events. Existing build, images and stored failure spans remain separate.

After Fountain adds backward reads, replace the raw-event fallback with a
provider cursor. Keep complete turn boundaries, prompt/image parity, archived
conversation order, unchanged SSE cursor, and the current race/access tests.
The network regression should then require one or two initial requests.
