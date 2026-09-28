# MCP reconciliation incident reproduction

The first sections record PR #303. The RAV-25 follow-up below replaces its raw journal.

Run `mix test bench/tooling_reconcile_test.exs`. This uses real receipts, queue rows,
PostgreSQL, the Fountain SDK, and `Fountain.FakeTransport` (including JSON decoding).
No production provider or credentials are used. Wall times and whole-VM reductions
include the mock and database dispatch, and are indicative rather than a production
CPU forecast. The synthetic clock advances persisted timestamps; it never sleeps.

Baseline: `da28f3b` (main at the start of this track). The same benchmark was run
against that commit's five affected production modules, then against this change.
Measurements on this Sprite:

| Workload | Before calls | After calls | Before reductions | After reductions |
| --- | ---: | ---: | ---: | ---: |
| 10 threads, 1,000 old + 200 reply events each, four running passes then completion | 210 | 170 | 16,790,684 | 13,993,171 |
| 10 unchanged working threads, 121 sweeps over 600 simulated seconds | 280 | 100 | 4,830,103 | 2,812,225 |

The first workload has one task per thread. Calls include `/turns` and `/events`.
Completion alone falls from 130 calls / 12,406,204 reductions to 90 calls /
8,982,844 reductions: it resumes after the four already consumed pages, rather
than starting at the beginning. Each of those pages contains 100 events, each
with a 256-byte output body. Total measured wall time was 338 vs 306 ms for the
first workload and 455 vs 302 ms for the second. Real provider latency is absent.

Component probe, 100 repetitions over the same 200-event reply:

| Component | Reductions | Wall time |
| --- | ---: | ---: |
| JSON decode | 7,324,042 | 56 ms |
| Previous `Transcript.page` reply parsing | 3,019,889 | 76 ms |
| `Transcript.blocks_for_turn` reply parsing | 1,250,623 | 17 ms |

The large event payloads and decoding dominate the payload probe. Reply parsing
also did unnecessary work: `Transcript.page` rebuilds the displayed transcript
as each event arrives; the receipt only needs the blocks for this one turn.
The regression suite additionally sends 1,000 transcript chunks while suspending
the reconciler and verifies that **zero** enter its mailbox; one settle event
still arrives. DB bookkeeping remains in the measurements above. These probes
do not establish which component dominates the production node.

## What the inspected baseline actually does

The current task reconciler already calls `events_page`, not `Fountain.events`.
A running receipt consumes at most one page per reconcile and stores its cursor.
A terminal turn explicitly resets the cursor to `nil` and replays its history.
Thus this baseline does **not** reproduce the reported full-history fetch on every
running backstop pass. It does reproduce terminal replay, the fixed polling
cadence, and subscription to every streamed chunk. The new trace hierarchy makes
those paths distinguishable in production.

Other full-history callers at this baseline:

- `Tracks.Setup.agent_failure/4`: scans history for a terminal opening turn.
- `Tracks.Setup.failure_reason/2`: scans history for an opening-turn failure reason.
- `PromptQueue.Server.failure_reason/2`: scans history when explaining an ended
  conversation with zero reported turns.
- `Tracks.read_transcript/3`: full transcript acquisition for a user-facing read.

These remain unchanged. Setup needs a turn-window/failure-reason contract and
its own regression coverage; changing its recovery behavior is not a trivial
caller substitution. The prompt-queue call is on an ended-conversation failure
path, and the transcript read intentionally requests history. PR #298 (now merged) bounds the new readiness measurement to its first 100 events;
it does not replay history.

## Durable state and limits

A per-thread/conversation high-water cursor commits atomically with the receipt and initializes
future receipts; existing receipts
keep their own durable cursor so an older or overlapping task cannot lose events.
A replacement Fountain conversation starts a separate checkpoint; stale readers
cannot reset a cursor already moved to that conversation.
Provider pages are shared within a thread pass. PR #303 initially used a temporary per-receipt journal that
retained only the correlated unfinished turn's events, preserving ACP replies and
failure evidence across pages and process loss; terminal writes clear it. Old
release receipts retain their latest partial text when first reconciled, including
writes made between the expand migration and deployment.

Backoff is 5, 60, 180, then 300 seconds for unchanged turns/events. A queue or
settle hint resets it and reconciles immediately. Generation checks prevent an
older pass from postponing a newer hint. Held-only and terminal threads are not
polled. The singleton election is unchanged; no process state is handed over.

Initial catch-up still reads historical pages once. Very large unfinished turns
could grow their temporary journal and parsing/DB cost in #303; the RAV-25
follow-up below removes that journal. A lost hint can delay discovery by the five-minute cap.
The retained text of legacy receipts cannot reconstruct raw failure evidence
already discarded by the previous release.


## RAV-25: remove the task-row journal

Run `mix test bench/tooling_journal_test.exs`. One unfinished turn receives 100
new events per pass, 256 output bytes per event, for 50 passes (5,000 events).
There are 100 provider calls on both versions. SQL telemetry sums `query_time`
and `decode_time`, including transactions and checkpoint work; it excludes queue
wait and the diagnostic row-size query. Reductions are whole-VM totals. Row size
is `octet_length(row_to_json(task)::text)`, an uncompressed logical size, not disk
usage. No real network latency is included.

The before run used the `b3c25c7` reconciliation implementation (including #303),
with the additive migration's empty fields already present. This small fixed
schema overhead is included in its row size. The after run uses this follow-up.

| 50 passes | Before | After |
| --- | ---: | ---: |
| Whole-VM reductions | 328,390,452 | 8,534,689 |
| Wall time | 6,173 ms | 349 ms |
| DB query + decode time | 5,142 ms | 145 ms |
| Last ten passes: mean reductions/pass | 11,563,778 | 163,398 |
| Last ten passes: mean DB time/pass | 183.2 ms | 3.3 ms |
| Task row at pass 50 | 2,053,655 bytes | 941 bytes |

The hot path now selects only small receipt fields, delivery state, thread IDs
and runtimes, and track setup state. It never selects `reply_events`, `reply_prefix`
or `result`. Each page appends only its new reply text to `tooling_reply_chunks`,
keyed by receipt and cursor. Receipt cursor, fragments and thread checkpoint
commit together; stale snapshots are rejected under the receipt lock. Successful
completion assembles the artifact once. Scoped artifact reads can assemble a
partial reply; ordinary sweeps do not.

Reply fragments retain the existing first 64,000-character artifact limit and
add a 256,000-byte UTF-8 bound for pathological combining characters. Output
beyond either cap is not stored, but all new events still advance the cursor and
feed failure classification. The failure summary retains only boolean protocol
signals, the maximum retry count (1–100), a prefix of the fixed timeout phrase,
and at most 512 characters of a generated suspension explanation. No raw event,
tool input or tool output is retained. The summary stays below 1 KiB in tests.
The classifier shares the existing structured-protocol predicates, and tests
compare it with full-turn detection across every split of the outage/suspension
fixtures. Retry and conversation replacement clear fragments and evidence.

`tooling.reconcile.thread` and `tooling.reconcile.compact` include
`ravix.task_payload_bytes_read` and `ravix.task_payload_bytes_written`. These count
JSON-encoded logical task fields/fragments handled by the application, including
one-time legacy conversion and terminal assembly; they are not PostgreSQL wire,
TOAST, WAL or index byte counters. Existing Ecto child spans report DB duration.

The migration only adds fields, a side table, an index and a trigger, so it can
run while the old release serves. New code converts legacy receipts once under
lock, preserving reply text and classifier evidence before clearing the raw
journal and prefix. The singleton also cleans at most five legacy receipts per
sweep, including terminal/held rows. A trigger marks old-release journal writes
for conversion again. No column is dropped. Conversion can still be expensive
once for a large pre-existing journal; it has its own span. Rollback to the old
application after conversion is not supported: it cannot read fragment storage.

This fixes the measured task-row growth; it does not claim a production CPU
result before deployment. Backoff, settle-only topics, durable cursors and the
singleton election remain as in #303. Full-history callers listed above remain
outside this storage follow-up.
