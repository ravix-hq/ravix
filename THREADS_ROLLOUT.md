# Threads rollout

Each track has a default thread whose ID equals the track ID. Other threads have
independent Fountain conversations, transcripts, prompt queues, read markers,
preview helper grants, drafts, and desktop notification identities. They share
the track's existing sandbox, branch, directory, membership, and preview service.
New threads start with no conversation history. Delivery supplies the existing
track's directory and branch; summary handoff is a possible follow-up.

## Expand and activate

1. Run migrations with the normal `ravix` prefix. Backfill threads and read
   markers. Triggers mirror old-release track inserts, conversation attaches,
   read markers, and queue inserts into the new representation. Existing channel
   IDs remain readable. New channels include a thread ID.
2. Deploy with `RAVIX_THREADS_ENABLED=false` (the production default). The
   previous release still reads and writes `tracks.conversation_id`, and old
   queue workers cannot route additional threads safely.
3. Drain every previous-release web instance and queue worker, then enable
   `RAVIX_THREADS_ENABLED=true` on every instance. Development/test enable it by
   default. Additional threads attach with the full Launch identity and the
   sandbox ID read from the track's default Fountain conversation.

Do not roll back to the old queue worker after activating additional threads
without first stopping delivery and draining their prompts. Disabling the add
button alone does not make an old worker understand existing additional threads.

## Later contract release

After the old release can no longer run, remove legacy default-conversation and
read-marker writers, their compatibility triggers, and the old queue-head index.
Only in a subsequent release that no longer reads these fields should a migration
drop `tracks.conversation_id` and `track_reads`. Keep the thread/track relationship
and database constraints; the default ID convention is part of the API.

No individual thread rename/close controls or summary handoff are included.
Closing a track cancels all its queued prompts and terminates all conversations.
Desktop notifications retain their existing event flow; notification identities
and click authorization now include the thread.
