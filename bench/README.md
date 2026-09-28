# MCP reconciliation incident reproduction

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
| 10 threads, 1,000 old + 200 reply events each, four running passes then completion | 210 | 170 | 16,790,684 | 13,917,090 |
| 10 unchanged working threads, 121 sweeps over 600 simulated seconds | 280 | 100 | 4,830,103 | 2,709,827 |

The first workload has one task per thread. Calls include `/turns` and `/events`.
Completion alone falls from 130 calls / 12,406,204 reductions to 90 calls /
8,974,114 reductions: it resumes after the four already consumed pages, rather
than starting at the beginning. Each of those pages contains 100 events, each
with a 256-byte output body. Total measured wall time was 338 vs 325 ms for the
first workload and 455 vs 292 ms for the second. Real provider latency is absent.

Component probe, 100 repetitions over the same 200-event reply:

| Component | Reductions | Wall time |
| --- | ---: | ---: |
| JSON decode | 7,322,126 | 56 ms |
| Previous `Transcript.page` reply parsing | 3,019,097 | 73 ms |
| `Transcript.blocks_for_turn` reply parsing | 1,251,623 | 17 ms |

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

A per-thread high-water cursor initializes future receipts; existing receipts
keep their own durable cursor so an older or overlapping task cannot lose events.
Provider pages are shared within a thread pass. A temporary per-receipt journal
retains only the correlated unfinished turn's events, preserving ACP replies and
failure evidence across pages and process loss; terminal writes clear it. Old
release receipts retain their latest partial text when first reconciled, including
writes made between the expand migration and deployment.

Backoff is 5, 60, 180, then 300 seconds for unchanged turns/events. A queue or
settle hint resets it and reconciles immediately. Generation checks prevent an
older pass from postponing a newer hint. Held-only and terminal threads are not
polled. The singleton election is unchanged; no process state is handed over.

Initial catch-up still reads historical pages once. Very large unfinished turns
can grow their temporary journal and parsing/DB cost; this change does not impose
a lossy transcript limit. A lost hint can delay discovery by the five-minute cap.
The retained text of legacy receipts cannot reconstruct raw failure evidence
already discarded by the previous release.
