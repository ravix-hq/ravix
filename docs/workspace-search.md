# Workspace search

Open **Search conversations** from the workspace navigation or visit `/search`.
Search words match case-insensitively using PostgreSQL's `simple` text parser;
all words must occur in a result. This is word search, not substring matching.
Project and track filters narrow the work you can already access. Results link
to projects, tracks, or the thread containing a conversation turn.

The local database searches project names/repositories, track names/branches,
remaining prompt-queue text, and durable selected conversation text. The query
never reads Fountain or loads whole transcripts into the search process. GIN
indexes serve each source, with 20 results per page, at most 1,000 pages,
ordered by source time descending then type and stable source ID. Excerpts are
plain, bounded text rendered through HEEx escaping. Filter menus show the first
200 accessible projects/tracks; URLs can also filter any accessible ID.

Completed turns are indexed when the existing settlement pipeline reads them.
Settlement requests the prompt blocks as well as the assistant output.
Transcript reads also persist up to 200 completed turns per loaded page,
including older conversations attached to a thread. Indexing finishes in the
context caller before its async transcript read returns, so no unowned task
survives the read. Writes are batched by conversation. The index
keeps human prompt text and ACP assistant text blocks only, up to 65,536
characters per role per turn. Attachments, tool arguments/results, reasoning,
raw stdout/stderr, provider credentials and event payloads are not indexed.
Replacing the newest Inbox reply excerpt does not remove prior search entries.

Conversation/turn/role identity deduplicates repeated ingestion across nodes.
Older event versions and shorter partial rereads cannot overwrite longer indexed
text. Deleting a thread cascades to its entries. No singleton or new polling
provider worker is needed: repeated indexing is idempotent on every instance.

History starts filling from this release. There is no deployment-wide provider
crawl: older transcript pages must be opened to backfill them, and unwatched
turns become searchable when Ravix reads them. Active turns are indexed after
completion. Sent or cancelled queue payloads still release their attachments;
delivered prompts enter durable search when their completed turn is ingested.
A deep link selects the owning thread; for an older turn you may need to load
earlier transcript pages. Only the project owner may search a visible closed track's history, matching
`Access.track_access`; former track/project/workspace members cannot.

Queries use `Accounts.Access.project_ids` and `Accounts.Access.visible` so a
track invitation does not admit private sibling tracks or project-level results.
Workspace memberships and private-track permissions count only under the
existing workspace access switch. Async results are checked again against
current membership, connected pages refresh on membership/track notices, and a
15-second access refresh is the backstop. Unsubmitted query/filter drafts
survive that refresh and incoming project notices. Malformed URL values are
rejected before rendering or database filtering, and search text writes suppress
Ecto parameter logs. Session hooks protect events,
messages and async completions; URL patches explicitly verify the live session.
