# Conversation load hotfix (RAV-25, r2-transcript-load)

Run from the repository root:

```sh
MIX_ENV=test mix run --no-start bench/transcript.exs --baseline
MIX_ENV=test mix run --no-start bench/transcript.exs
```

The baseline loads the original transcript implementation at
`b3c25c78956916e72fdc6f97a3c7b41e0bbc88f3` under a separate module name. The
only adaptation is its empty internal accumulator, since that representation
changed. Each size contains exactly the indicated number of events, with
interleaved text/thinking/tool calls followed by delayed tool results and a
settled turn. The wire shapes come from the existing ACP regression tests;
these are synthetic logs, not private production conversations. Measurements
are medians of three runs after warming modules, on this Sprite (OTP 28,
Elixir 1.19). They measure the CPU pipeline used by `Tracks.read_transcript`,
excluding provider/DB latency and LiveView rendering.

| Events | Before build (ms) | After build (ms) | Before reductions | After reductions |
| ---: | ---: | ---: | ---: | ---: |
| 200 | 23.57 | 1.08 | 728,978 | 88,002 |
| 1,000 | 569.26 | 5.52 | 13,678,734 | 442,559 |
| 2,000 | 2,235.90 | 14.28 | 52,524,981 | 894,334 |
| 4,000 | 11,620.95 | 46.73 | 210,965,460 | 1,804,623 |

The reductions isolate the superlinear work: doubling 1,000 to 2,000 and
2,000 to 4,000 events approximately quadrupled build work. It now doubles.
Elapsed time is sensitive to allocations/GC and scheduling; the largest build
remains well below one second. Image attachment measured below 0.01 ms in this
single-turn fixture. The former additional failure rescan cost 90.71 ms and
7,270,494 reductions at 4,000 events; it no longer runs on reads. The benchmark
still prints that legacy step to show its separate cost, not as part of the
new pipeline.

The dominant cause was `finish/2` running per event: it materialized all prior
blocks, filtered them, and scanned them for GitHub notices. Turn lookup and
delayed tool-result pairing also walked growing lists. Batches now index turns,
fold all events, and materialize each turn once. Tool results update a map;
text chunks accumulate as iodata; replaced plans leave skipped positions.
`github_notice/2` computes elapsed time once, rather than once per tool block.
No Markdown rendering runs in this context pipeline.

`test/fixtures/acp/transcript-golden.json` was generated with:

```sh
MIX_ENV=test mix run --no-start bench/transcript.exs --baseline --golden
```

The regression compares public output with that baseline for the reported
Codex outage fixture and reconstructed ACP shapes: delayed/reused/orphan tool
IDs, interleaved turns, chunk joining, plan replacement/removal, malformed
frames, duplicates and out-of-order events. Encoded JSON payloads are compared
as decoded values because Erlang map iteration order can vary across VMs.
Internal accumulators and the new source-conversation identity are excluded.
Existing transcript tests additionally cover prompts, retained images,
suspension, setup visibility and tool details.

## Read and settlement behavior

`tracks.events` now contains `transcript.build` (with `ravix.event_count`),
`transcript.images`, and `transcript.failures` (stored-correction lookup).
`transcript.failure_detection` measures classification at settlement instead.
For a settled turn with no stored classification, the read returns immediately
and starts catch-up under `Ravix.TaskSupervisor`. The task reuses the already
loaded events rather than fetching them again. A cluster-wide name per
conversation/turn excludes overlapping workers, and the database marker/lock
also protects against concurrent node joins. `transcript.background` traces
this asynchronous work. A newly stored failure publishes a hub event so the
open page picks it up through incremental catch-up, including failures from
archived conversations. Worker failure leaves no completion marker; another
read can retry.

Successful as well as failed classifications get durable completion markers;
a transaction lock prevents duplicate classification across follower restarts
or concurrent backfills. Provider acquisition happens outside that lock. An
acquisition failure leaves no marker and the follower resumes without advancing
past the unsettled event. Existing queue/setup failure corrections are retained.

The minute tick and streamed stage flush perform no transcript read. Hub repair
and follower replacement fetch only events after the page cursor. Full reads
remain for initial load, thread switches and binding changes. A changed source
conversation invalidates the cursor. Existing historical turns and image counts
survive catch-up.

## Operational limits

Initial loads still acquire the full provider event history and retained image
metadata. Settlement of a previously unclassified turn also acquires history
once to get complete evidence, then classifies only that turn. Sandbox-wide
suspensions need history to identify the preceding open turn. This hotfix does
not introduce a transcript cache or change Markdown rendering.

Settled turns without a stored correction are classified automatically in the
background when read, including turns that finished with no follower running.
The first page can briefly lack an inferred correction until that worker
publishes its result. Repeated reads skip completed/in-flight work. Classification
is never awaited by the reader. An explicit bulk maintenance command also remains:

```sh
mix ravix.backfill_turn_failures THREAD_ID [THREAD_ID ...]
```

It includes the thread's previous conversations, skips live turns, and can be
resumed safely. No production backfill has been run. Raw failure-stage blocks
remain visible immediately, independently of inferred failure corrections.
