# Webhook routines

Open **Schedules → Webhook routines**, choose a project, and save a name and
prompt. Only the creator can manage their routine, and every operation requires
current project write access. A track share alone does not qualify. Each delivery
runs as the creator using the normal track billing and durable prompt queue.

Copy the credential shown after creation; it cannot be retrieved again. Rotation
shows a new credential once and immediately invalidates the old one. Dismiss the
credential after saving it in your webhook sender's secret configuration. It is
sent in the Authorization header, never in the URL. Only its SHA-256 hash is
persisted. Use HTTPS outside local development.

```sh
curl --request POST "$RAVIX_URL/api/routines/$ROUTINE_ID/webhook" \
  --header "Authorization: Bearer $ROUTINE_CREDENTIAL" \
  --header 'Content-Type: application/json' \
  --header 'Idempotency-Key: source-event-123' \
  --data '{"issue_number":123,"summary":"Example event"}'
```

The body must be a JSON object, at most **32,768 bytes**, including whitespace.
The saved prompt is limited to 15,000 characters. The event is appended as a
clearly delimited JSON string with an explicit instruction to treat it as data.
A delivery cannot select provider credentials, override the saved prompt, choose
an existing track, or execute a separate command. As with any prompt sent to an
agent, configure the saved prompt for the external data you trust it to process.

Use a stable, unique **Idempotency-Key** (1–128 bytes) for each source event. Keys
are scoped to the routine and retained until it is deleted. Concurrent deliveries
with the same key create one dispatch. A retry with equivalent JSON (including
reordered object keys) returns the same dispatch; changed event data returns 409.
Credential rotation does not reset delivery identities.

Responses:

| HTTP | Meaning |
| --- | --- |
| 202 | New durable dispatch; inspect `status`, `id`, and `track_id` |
| 200 | Duplicate; original outcome returned, no new track |
| 400 | Missing headers, invalid key, malformed JSON, or a non-object body |
| 401 | Invalid credential, deleted routine, or revoked creator project access |
| 403 | Routine paused |
| 409 | Key was already used with different JSON data |
| 413 | Body exceeds the size limit |
| 415 | Content-Type must be application/json |
| 503 | Database dispatch admission unavailable |

Refresh and select **Recent dispatches** to inspect the last 20 deliveries and
open their tracks. `queued` means the prompt entered the normal queue, not that
the agent finished. `open_failed`, `queue_failed`, and `interrupted` are terminal
outcomes requiring inspection before submitting a new event ID. `dispatching`
means completion was not confirmed (including a process crash). Claims commit
before external effects and are **never automatically replayed**, preventing
uncertain provider effects from opening duplicate tracks. If a track is known,
its link is retained even when queueing fails.

Pausing, deleting, rotating the credential, or removing the creator's project
write permission stops future admissions. Already admitted deliveries may finish;
track creation and prompting recheck access. Deleting a routine deletes delivery
history but preserves its tracks. External bodies are not stored in delivery
history or request logs; the event data is included in the track's saved prompt.
