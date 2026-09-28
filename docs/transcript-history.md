# Transcript history (RAV-28)

Opening a thread reads **one** newest-first page of its current conversation:
`GET /api/conversations/:id/events?order=desc&whole_turns=true&prompts=true&limit=200`
([managoat/fountain#2531](https://github.com/managoat/fountain/issues/2531)).
The page renders as it is, and the live follow resumes from its
`page.newest_cursor` (the SSE `Last-Event-ID`). Nothing older is downloaded until
somebody asks for it.

## Page size

A read is sized by turns, not events. `whole_turns` extends a page to the first
event of every turn it touches, up to Fountain's 5,000-event ceiling, so
`limit` is only where the page starts looking: in production, `limit=50`
returned 1,001 events of one long turn with `turn_split: false`.

The newest page of 30 recent Fountain conversations held 54 complete turns: 23
under 200 events, and 31 from 275 to 2,915 (median about 850). Reads therefore
ask for `limit=200`: several short turns, or the newest long turn whole, and
never more than one page of a turn the reader is about to see. A 5,000-event
single-turn page renders in about 35 ms and holds about 1.1 MB as a page (the
turn keeps its events, as a full build's does); only the cursor is retained
after it. The background classification scan asks for `limit=1000`, so its
page budget covers more history. The browser fixture's 20-event turns open ten
at a time.

## Load earlier

`Transcript.History` is a cursor, not retained events. `before` is the loaded
page's `meta.next_cursor`; Load earlier reads `before=<cursor>` with
`whole_turns=true`, one request per page, then opens older conversations
(`previous_conversation_ids`) newest first the same way. Cursors are only ever
ids Fountain returned; event ids are global and sparse, so none is computed.

A page's older edge can be incomplete in two ways, and those events are
**held** rather than rendered, then rendered with the page they continue on:

- `page.turn_split`: a turn larger than Fountain's 5,000-event ceiling was cut.
  Every turn whose `turn`/`started` event is not on the page, with the turns
  interleaved with it, is held.
- Turn-less output (setup before turn 1, sandbox stage events) pages by `limit`
  alone, so a run at the bottom of a page may continue below it, or be a
  suspension that belongs to the turn before it. The leading turn-less run is
  held while older events exist.

So a turn split across pages renders once, whole, exactly as a full build of
the conversation would render it; the history tests compare the whole walk
with a full build. A page held entirely reads the next page at once rather
than rendering nothing, but one read takes at most three pages. At that point
held turn-less output renders as far as it was read (its older part renders as
a block of its own when loaded), while a turn cut by the ceiling stays held
and Load earlier reads on, so it is never rendered in halves.

Each Load earlier task receives the cursor, the held events and the
conversation's turn records (image counts), and returns only its new turns.
Access is checked again for each earlier read and each LiveView async result.
LiveView inserts only the earlier turns at the beginning of its stream; the
browser anchors the first visible article across the patch. A repair read that
starts the thread over keeps history already loaded further back
(`History.further?/2`).

## Classification

Settled turns must be classified (`Ravix.Tracks.Settlement`) even when nobody
scrolls to them, and there is no full log to scan any more. Each open starts a
supervised background scan: it classifies the settled turns on the page it
has, then pages **backward** (`before`, whole turns) only until it reaches a
settled turn that is already classified. A page with no settled turn at all (a
running turn over the limit) stops it too, unless nothing in the conversation
has been classified yet. Classification is durable, so steady
state reads no further page, and the first open of an old conversation walks
back once, at most 20 pages, off the read path. One walk per conversation runs
at a time (a `:global` lock), and the per-turn `:settlement` registration and
durable transaction deduplicate the classifications themselves. Load earlier
pages enqueue their own unclassified settled turns.

## Older Fountain

A response without the `page` object is a Fountain older than #2531, which
ignored `order` and answered its oldest page forward. That page is not wasted:
the read continues forward from it (`Fountain.events(from: page)`) and falls
back to the whole-log path of #311: complete-turn chunks of ten, retained
locally, and a background classification of the whole log.

## Traces

`tracks.events` and `tracks.events.earlier` carry `ravix.event_pages`,
`ravix.events_fetched` and `ravix.events_order` (`desc`, or `asc` for the
fallback and catch-up), with the rendered `ravix.event_count` and
`ravix.turn_count`. The scan's `transcript.classification_scan` span records
the pages it read back as `ravix.event_pages`.
