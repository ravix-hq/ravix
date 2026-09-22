defmodule Ravix.PromptQueue.Store do
  @moduledoc """
  The queue rows, with nobody's permission established.

  A queued prompt is unusual among this application's rows in that it outlives
  the request that made it: somebody types while the machine is still starting,
  the request ends, and delivery happens later on a sweep with no caller at
  all. So the worker's half of the queue was never scoped and could not be --
  there is no user in hand at the moment a prompt is finally sent.

  What it was, until now, was the bottom half of `Ravix.PromptQueue` under a
  divider reading "the worker's side (server/db.ts prompt_queue)", which is
  the `server/db.ts` seam the port left in every context. `Ravix.PromptQueue`
  keeps the three functions a person calls, each of which goes through
  `Ravix.Accounts.Access` first; everything here takes ids.

  The one function that decides anything about access is
  `Ravix.PromptQueue.Server.authorized?/1`, and it deliberately re-establishes
  the sender through `Access.track_access/2` at delivery time rather than
  trusting what was true when the prompt was accepted.
  """

  import Ecto.Query

  alias Ravix.Hub
  alias Ravix.PromptQueue
  alias Ravix.PromptQueue.Body
  alias Ravix.PromptQueue.Item
  alias Ravix.Repo
  alias Ravix.Tracks.Store, as: Tracks
  alias Ravix.Tracks.Track

  @typedoc "A row without its payload, plus what the payload said, for the panel."
  @type summary :: %{
          sequence: integer(),
          id: String.t(),
          track_id: String.t(),
          user_id: String.t(),
          author_login: String.t(),
          created_at: DateTime.t(),
          status: Item.status(),
          error: String.t() | nil,
          prompt: String.t() | nil,
          image_count: non_neg_integer()
        }

  @max_waiting 20

  @max_payload_bytes 12 * 1024 * 1024

  @done [:sent, :cancelled]

  # The other four, spelled out rather than derived, because they are also
  # spelled out in the migration that indexes them
  # (`prompt_queue_thread_heads`), and a query only gets that index when
  # Postgres can prove its predicate from the query's. `status NOT IN
  # ('sent', 'cancelled')` is the same set to a reader and not to the
  # planner, which does not know the column's domain; `status IN (these
  # four)` is a clause it can match. The check below keeps the two lists one
  # set.
  @live ~w(queued sending failed unconfirmed)a

  if Enum.sort(@live ++ @done) != Enum.sort(Item.statuses()) do
    raise CompileError,
      description: "Ravix.PromptQueue.Store: @live and @done must cover Item.statuses/0 exactly"
  end

  @claim_timeout_ms 6 * 60_000

  @restart_error "The server restarted during delivery. Check the transcript before sending this again."

  @doc """
  Save a prompt for `track_id`, or return the receipt an earlier save left.

  `id` is the caller's request id (16 to 80 letters, digits and dashes); a
  repeated submission with the same id returns the same row, even after it
  was delivered. The receipt check, the cap of twenty waiting prompts per
  track and the insert were one atomic step when the database was
  synchronous; the transaction (with the track row locked) keeps them so.

  `body` is a `Ravix.PromptQueue.Body`, or anything
  `Ravix.PromptQueue.Body.decode/1` can read as one; it is stored as `jsonb`
  and refused above 12 MiB.
  """
  @spec enqueue(String.t(), String.t(), String.t(), term(), Body.t() | map(), String.t() | nil) ::
          {:ok, Item.t()} | {:error, PromptQueue.reason()}
  def enqueue(track_id, user_id, author_login, id, body, thread_id \\ nil) do
    thread_id = thread_id || track_id

    with :ok <- validate_request_id(id),
         {:ok, encoded} <- encode(body),
         {:ok, {item, inserted?}} <-
           Repo.transaction(fn ->
             enqueue_locked(track_id, user_id, author_login, id, encoded, thread_id)
           end) do
      if inserted?, do: publish_queue(track_id)
      {:ok, item}
    end
  end

  # Inside the transaction. The receipt check, the cap of twenty waiting
  # prompts per track and the insert were one atomic step when the database
  # was synchronous, and they stay one here: the track row is locked so two
  # saves for one track cannot both pass the cap, and the unique index on id
  # covers the receipt. Returns the row and whether this call inserted it.
  #
  # Refusing means `Repo.rollback/1`, so there is exactly one place that
  # does it, in the same `with`-then-rollback shape as `cancel_locked/4` and
  # `retry_locked/4` next door. It used to be four places in three
  # functions, one of which was `encode/1` --- turning a payload into JSON,
  # which touches no row and had no business ending a transaction. Encoding
  # happens before this opens now, so a prompt too large to store is refused
  # without taking a lock it was never going to use.
  defp enqueue_locked(track_id, user_id, author_login, id, encoded, thread_id) do
    with {:ok, _track} <- lock_track(track_id),
         {:ok, existing} <- receipt(id, track_id, user_id, thread_id),
         {:ok, _room} <- room(existing, thread_id) do
      case existing do
        %Item{} -> {existing, false}
        nil -> {insert(track_id, user_id, author_login, id, encoded, thread_id), true}
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The same request id twice is the same prompt, even after it was
  # delivered; the same id on somebody else's track or from somebody else is
  # a collision and must not answer with their row.
  defp receipt(id, track_id, user_id, thread_id) do
    case get(id) do
      %Item{track_id: ^track_id, user_id: ^user_id, thread_id: ^thread_id} = existing ->
        {:ok, existing}

      %Item{} ->
        {:error, {:conflict, "request_id_used", "Use a new request id."}}

      nil ->
        {:ok, nil}
    end
  end

  defp room(%Item{}, _track_id), do: {:ok, :held}

  defp room(nil, track_id) do
    if waiting_count(track_id) >= @max_waiting do
      {:error,
       {:conflict, "queue_full",
        "This track already has #{@max_waiting} saved prompts. Cancel one or wait for it to run."}}
    else
      {:ok, :free}
    end
  end

  @doc "One row by its request id, payload included, whatever its status."
  @spec get(String.t()) :: Item.t() | nil
  def get(id), do: Repo.get_by(Item, id: id)

  @doc "Every live row (not sent, not cancelled), oldest first; on one track when given."
  @spec queued_prompts(String.t() | nil) :: [Item.t()]
  def queued_prompts(track_id \\ nil) do
    live()
    |> maybe_on_track(track_id)
    |> order_by([p], p.sequence)
    |> Repo.all()
  end

  @doc """
  The first live row on every track, without the bytes.

  Not every queued attachment on every sweep: only the first live row per
  track can be delivered, and its bytes are loaded just before the POST. A
  failed or unconfirmed head is returned too, so that later instructions
  cannot overtake one whose outcome needs a person.

  One pass over `prompt_queue_thread_heads`, the partial index on
  `(thread_id, sequence)` over live rows, which is in exactly the order
  `DISTINCT ON (thread_id) ... ORDER BY thread_id, sequence` wants. It used to
  be a `min(sequence) GROUP BY track_id` subquery, which read every row of
  the table -- delivered ones included, and they are nearly all of it -- on
  every instance, on every sweep. The rows come back grouped by track
  rather than oldest first; the sweep delivers tracks in parallel and in no
  order, so nothing read the order.
  """
  @spec heads() :: [Item.t()]
  def heads do
    # Neither the parsed body nor its JSON string: the head is read every two
    # seconds per track and the attachments are loaded once, just before the
    # POST.
    fields = Item.__schema__(:fields) -- [:body, :payload]

    live()
    |> distinct([p], p.thread_id)
    |> order_by([p], p.sequence)
    |> select([p], struct(p, ^fields))
    |> Repo.all()
  end

  @doc """
  The live rows of a track with the prompt and the image count, for the panel.

  Both are read straight off the row. They used to be cast out of a `text`
  column in the query -- `NULLIF(?, '')::jsonb->>'prompt'` and
  `jsonb_array_length(...)` -- with the `NULLIF` defending against the empty
  string a released payload was set to. `body` is `jsonb` and `image_count`
  is a column, so neither cast nor sentinel is needed.
  """
  @spec summaries(String.t(), String.t() | nil) :: [summary()]
  def summaries(track_id, thread_id \\ nil) do
    thread_id = thread_id || track_id

    live()
    |> where([p], p.track_id == ^track_id and p.thread_id == ^thread_id)
    |> order_by([p], p.sequence)
    |> select([p], %{
      sequence: p.sequence,
      id: p.id,
      track_id: p.track_id,
      user_id: p.user_id,
      author_login: p.author_login,
      created_at: p.created_at,
      status: p.status,
      error: p.error,
      prompt: fragment("? ->> 'prompt'", p.body),
      image_count: p.image_count
    })
    |> Repo.all()
  end

  @doc """
  Move a row to `status` with `error`, unless it is already done.

  The id stays behind as a receipt for retried HTTP requests; a `:sent` or
  `:cancelled` row releases its payload, keeping `image_count` so the panel
  can still say what was sent. Nothing here checks who is asking:
  the server calls it on rows it is delivering, `cancel/3` and `retry/3`
  call it inside a transaction that established the person's right to.
  """
  @spec set_status(String.t(), Item.status(), String.t() | nil) :: :ok
  def set_status(id, status, error \\ nil) do
    released = if status in @done, do: [body: nil, payload: ""], else: []

    {_count, tracks} =
      Item
      |> where([p], p.id == ^id and p.status not in ^@done)
      # Nothing to tell anyone when the row already says this. The queue
      # server re-parks its head on every sweep while a machine is waking
      # or Fountain is unreachable, and every publish makes each open track
      # page re-read its transcript from Fountain -- so an unguarded write
      # turns a 15-second poll into a 2-second one against a dependency that
      # is already failing, per viewer, for as long as the outage lasts.
      |> where([p], p.status != ^status or fragment("? IS DISTINCT FROM ?", p.error, ^error))
      |> select([p], p.track_id)
      |> Repo.update_all(set: [status: status, error: error] ++ released)

    Enum.each(tracks, &publish_queue/1)
  end

  @doc """
  Replace the message on a row that is still `status`, and on no other.

  For a finding about a row the server did not claim: something a person can
  move at the same moment (`retry/3` turns an `:unconfirmed` row back into a
  `:queued` one), where `set_status/3` would put the old status back over
  theirs.
  """
  @spec annotate(String.t(), Item.status(), String.t()) :: :ok
  def annotate(id, status, error) do
    {_count, tracks} =
      Item
      |> where([p], p.id == ^id and p.status == ^status)
      |> where([p], fragment("? IS DISTINCT FROM ?", p.error, ^error))
      |> select([p], p.track_id)
      |> Repo.update_all(set: [error: error])

    Enum.each(tracks, &publish_queue/1)
  end

  @doc """
  Take a queued row for delivery. False when it was not queued any more:
  cancelled meanwhile, or claimed by another sweep.
  """
  @spec claim(String.t()) :: boolean()
  def claim(id) do
    {count, tracks} =
      Item
      |> where([p], p.id == ^id and p.status == :queued)
      |> select([p], p.track_id)
      |> Repo.update_all(set: [status: :sending, error: nil, claimed_at: DateTime.utc_now()])

    Enum.each(tracks, &publish_queue/1)
    count == 1
  end

  @doc """
  Rows whose claim has outlived any task that could still be holding it.

  A `:sending` row may or may not have reached Fountain, so it becomes
  `:unconfirmed` for a person to check and is never replayed blindly. What
  the claim age decides is *which* rows those are. Reclaiming every
  `:sending` row would replay one that a surviving task is still POSTing --
  the delivery tasks are supervised beside this server, not under it, so they
  outlive its restart, and a deploy overlaps two instances entirely. Waiting
  out `claim_timeout_ms/0` instead means only a claim nothing can still be
  working on is taken back, which also unsticks a row whose task died between
  the POST and the status write: `:sending` is refused by both `cancel/3` and
  `retry/3`, so without this it would hold its track's head forever.

  A row with no `claimed_at` was claimed before this column existed and is
  treated as stale.

  `status = 'sending'` is written first and on its own so that the query
  matches `prompt_queue_sending_claims`, the partial index over only those
  rows: there are seldom any, and this runs on every instance every two
  seconds.
  """
  @spec recover() :: :ok
  def recover do
    cutoff = DateTime.add(DateTime.utc_now(), -claim_timeout_ms(), :millisecond)

    {_count, tracks} =
      Item
      |> where([p], p.status == :sending)
      |> where([p], is_nil(p.claimed_at) or p.claimed_at < ^cutoff)
      |> select([p], p.track_id)
      |> Repo.update_all(set: [status: :unconfirmed, error: @restart_error])

    tracks |> Enum.uniq() |> Enum.each(&publish_queue/1)
  end

  @doc """
  Record a prompt as delivered, even if the track closed while it was in
  flight.

  The only writer that can put a `:sending` row into `:cancelled` is
  `cancel_track/1` -- an explicit `cancel/3` refuses that status -- so this
  runs when a track closed between the POST and its answer. The prompt did
  reach Fountain and is running, and `set_status/3` would refuse the write
  because `:cancelled` is already a done status, leaving the queue claiming
  it was cancelled. Only success may take this door: a late *failure* still
  cannot move a cancelled row, which is what stops a closed track's queue
  coming back to life.
  """
  @spec mark_delivered(String.t()) :: :ok
  def mark_delivered(id) do
    {_count, tracks} =
      Item
      |> where([p], p.id == ^id and p.status != :sent)
      |> select([p], p.track_id)
      |> Repo.update_all(set: [status: :sent, error: nil, body: nil, payload: ""])

    Enum.each(tracks, &publish_queue/1)
  end

  @doc """
  How long a claim is honoured before `recover/0` may take it back. Longer
  than the server's own delivery timeout, so a task that is about to be
  killed for running long still settles its own row first.
  """
  @spec claim_timeout_ms() :: pos_integer()
  def claim_timeout_ms, do: @claim_timeout_ms

  @doc "Cancel everything on a track that has not been sent: the track closed, or its project went."
  @spec cancel_track(String.t()) :: :ok
  def cancel_track(track_id) do
    Item
    |> where([p], p.track_id == ^track_id and p.status != :sent)
    |> Repo.update_all(set: [status: :cancelled, body: nil, payload: "", error: nil])

    publish_queue(track_id)
  end

  defp validate_request_id(id) when is_binary(id) do
    if Regex.match?(~r/^[a-zA-Z0-9-]{16,80}$/, id), do: :ok, else: request_id_required()
  end

  defp validate_request_id(_id), do: request_id_required()

  defp request_id_required,
    do:
      {:error,
       {:unprocessable, "request_id_required", "Send a unique request id with this prompt."}}

  # The track row is locked for the rest of the transaction so two saves for
  # one track cannot both pass the cap; the unique index on id covers the
  # receipt.
  defp lock_track(track_id) do
    Track
    |> where([t], t.id == ^track_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %Track{} = track -> {:ok, track}
    end
  end

  defp waiting_count(track_id),
    do: live() |> where([p], p.thread_id == ^track_id) |> Repo.aggregate(:count)

  # The stored document, plus the JSON string of it for the release that
  # still reads `payload`. The size is measured on the encoded bytes because
  # that is what goes over the wire and onto the disk, whatever the struct
  # costs in memory.
  #
  # Either spelling still enqueues, which the test named "string keys are
  # accepted" is about. What changed is that the tolerance is
  # `Body.decode/1`'s, in one place, rather than a pair of
  # `Map.get(payload, :prompt) || Map.get(payload, "prompt")` written out
  # here and nowhere near the `payload["images"]` that read it back.
  defp encode(body) do
    document = body |> Body.decode() |> Body.encode()
    encoded = Jason.encode!(document)

    if byte_size(encoded) > @max_payload_bytes do
      {:error,
       {:unprocessable, "prompt_too_large",
        "This prompt has too many image bytes. Send fewer images."}}
    else
      {:ok, {document, encoded}}
    end
  end

  defp insert(track_id, user_id, author_login, id, {document, encoded}, thread_id) do
    %Item{}
    |> Item.changeset(%{
      id: id,
      track_id: track_id,
      thread_id: thread_id,
      user_id: user_id,
      author_login: author_login,
      body: document,
      image_count: length(document["images"]),
      payload: encoded
    })
    |> Repo.insert!()
  end

  # Literal, not a parameter: see `@live`.
  defp live, do: where(Item, [p], p.status in @live)
  defp maybe_on_track(query, nil), do: query
  defp maybe_on_track(query, track_id), do: where(query, [p], p.track_id == ^track_id)
  # The panel re-reads a track's queue on this. Publishing is by project,
  # which the row does not carry; one read of the track finds it.
  defp publish_queue(track_id) do
    # ownership: no door here, on purpose. Every writer in this store ends by
    # telling the page, and not every writer has a person behind it: enqueue,
    # cancel and retry went through `Access.track_access/2`, but the server's
    # own status moves, `recover/0` and `cancel_track/1` have no user at all.
    # The read decides nothing -- the row is already written, and this only
    # turns its track id into the project whose hub is told.
    case Tracks.get_track(track_id) do
      %Track{project_id: project_id} -> Hub.publish(project_id, :queue, track_id: track_id)
      nil -> :ok
    end
  end

  @doc """
  The row, locked for the rest of the caller's transaction, if it is on this
  track.

  Public because `Ravix.PromptQueue` needs the lock and the authorization
  check to happen together: cancelling or retrying somebody else's prompt is
  refused *after* the row is held, so two callers cannot both pass.
  """
  @spec lock_row(String.t(), String.t()) :: {:ok, Item.t()} | {:error, :not_found}
  def lock_row(id, track_id) do
    Item
    |> where([p], p.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %Item{track_id: ^track_id} = row -> {:ok, row}
      _ -> {:error, :not_found}
    end
  end
end
