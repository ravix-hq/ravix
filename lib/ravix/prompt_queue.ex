defmodule Ravix.PromptQueue do
  @moduledoc """
  Accepted prompts awaiting delivery, which must outlive the browser that
  submitted them.

  Every prompt is saved here before the caller is told "saved". Text and
  attached images stay while another turn runs; closing a tab, changing
  tracks, or restarting the server does not discard waiting work.
  `Ravix.PromptQueue.Server` delivers the first live row per track to
  Fountain when the conversation is idle.

  Three functions are user-facing and take the `%User{}`: `list/2`,
  `cancel/3` and `retry/3` go through `Ravix.Accounts.Access.track_access/2`
  first. `enqueue/5` takes ids because its caller, `Ravix.Tracks.prompt/3`,
  has already established that the person is on the track (the receipt and
  the cap are checked here, in one transaction). The rest are the worker's
  side of the table, as `server/db.ts` had them: no person is involved, and
  they are called by the server, by a context that owns the track (closing
  it, archiving its project), or by a test.

  Every change to a track's queue publishes a `"queue"` event on the
  project's `Ravix.Hub` topic so the saved-prompts panel re-reads it; the
  TypeScript polled instead.
  """

  import Ecto.Query

  alias Ravix.Accounts.{Access, User}
  alias Ravix.Hub
  alias Ravix.PromptQueue.Item
  alias Ravix.Repo
  alias Ravix.Tracks.Track

  @type reason ::
          :not_found
          | {:forbidden, String.t()}
          | {:conflict, String.t(), String.t()}
          | {:unprocessable, String.t(), String.t()}

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

  @typedoc "What `shared/api.ts` calls a `QueuedPrompt`."
  @type queued_prompt :: %{
          id: String.t(),
          prompt: String.t() | nil,
          image_count: non_neg_integer(),
          author_login: String.t(),
          created_at: DateTime.t(),
          status: Item.status(),
          error: String.t() | nil,
          can_cancel: boolean()
        }

  @max_waiting 20
  @max_payload_bytes 12 * 1024 * 1024
  @done [:sent, :cancelled]
  @claim_timeout_ms 6 * 60_000

  @restart_error "The server restarted during delivery. Check the transcript before sending this again."

  # ── the person's side ─────────────────────────────────────────────────

  @doc """
  Save a prompt for `track_id`, or return the receipt an earlier save left.

  `id` is the caller's request id (16 to 80 letters, digits and dashes); a
  repeated submission with the same id returns the same row, even after it
  was delivered. The receipt check, the cap of twenty waiting prompts per
  track and the insert were one atomic step when the database was
  synchronous; the transaction (with the track row locked) keeps them so.

  `payload` is `%{prompt: text, images: [%{data, media_type}]}` (atom or
  string keys); it is stored as JSON and refused above 12 MiB.
  """
  @spec enqueue(String.t(), String.t(), String.t(), term(), map()) ::
          {:ok, Item.t()} | {:error, reason()}
  def enqueue(track_id, user_id, author_login, id, payload) do
    with :ok <- validate_request_id(id),
         {:ok, {item, inserted?}} <-
           Repo.transaction(fn ->
             enqueue_locked(track_id, user_id, author_login, id, payload)
           end) do
      if inserted?, do: publish_queue(track_id)
      {:ok, item}
    end
  end

  @doc "The waiting prompts on a track, as the saved-prompts panel shows them."
  @spec list(User.t(), String.t()) :: {:ok, [queued_prompt()]} | {:error, reason()}
  def list(%User{} = user, track_id) do
    with {:ok, %{role: role}} <- Access.track_access(user, track_id) do
      {:ok, track_id |> summaries() |> Enum.map(&present(&1, role, user))}
    end
  end

  @doc """
  Cancel a waiting prompt. The sender or the project owner may; a prompt
  already being delivered cannot be (stop the turn instead).

  The row is read and changed in one step, so the worker cannot claim it in
  between, which the synchronous database ruled out by construction.
  """
  @spec cancel(User.t(), String.t(), String.t()) :: :ok | {:error, reason()}
  def cancel(%User{} = user, track_id, id) do
    with {:ok, %{role: role}} <- Access.track_access(user, track_id),
         {:ok, :ok} <- Repo.transaction(fn -> cancel_locked(id, track_id, role, user) end) do
      :ok
    end
  end

  @doc "Send a refused or unconfirmed prompt again, explicitly. Same rule of who may as `cancel/3`."
  @spec retry(User.t(), String.t(), String.t()) :: :ok | {:error, reason()}
  def retry(%User{} = user, track_id, id) do
    with {:ok, %{role: role, track: track}} <- Access.track_access(user, track_id),
         {:ok, :ok} <- Repo.transaction(fn -> retry_locked(id, track, role, user) end) do
      :ok
    end
  end

  @doc "A `QueuedPrompt` from a summary, for `role` and the person looking."
  @spec present(summary(), :owner | :member, User.t()) :: queued_prompt()
  def present(row, role, %User{id: user_id}) do
    %{
      id: row.id,
      prompt: row.prompt,
      image_count: row.image_count,
      author_login: row.author_login,
      created_at: row.created_at,
      status: row.status,
      error: row.error,
      can_cancel: row.status != :sending and (role == :owner or row.user_id == user_id)
    }
  end

  @doc """
  The prompt as the agent receives it on a shared track: `[from @login] ...`.

  Fountain's turn carries a prompt and nothing about who typed it, so once a
  track has more than one person in it the author is written into the prompt
  and the transcript reads it back off for display (`shared/author.ts`). A
  solo track is not prefixed: your own name on your own prompt reads as the
  app talking to itself.
  """
  @spec with_author(String.t(), String.t()) :: String.t()
  def with_author(login, prompt), do: "[from @#{login}] #{prompt}"

  # ── the worker's side (server/db.ts prompt_queue) ─────────────────────

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
  The first live row on every track, without payloads.

  Not every queued attachment on every sweep: only the first live row per
  track can be delivered, and its bytes are loaded just before the POST. A
  failed or unconfirmed head is returned too, so that later instructions
  cannot overtake one whose outcome needs a person.
  """
  @spec heads() :: [Item.t()]
  def heads do
    first = live() |> group_by([p], p.track_id) |> select([p], min(p.sequence))
    fields = Item.__schema__(:fields) -- [:payload]

    Item
    |> where([p], p.sequence in subquery(first))
    |> order_by([p], p.sequence)
    |> select([p], struct(p, ^fields))
    |> Repo.all()
  end

  @doc """
  The live rows of a track with `prompt` and `image_count` read out of the
  JSON payload, for the panel. A delivered or cancelled row has an emptied
  payload, which is not JSON; those rows are filtered out, and `NULLIF`
  keeps the cast honest anyway.
  """
  @spec summaries(String.t()) :: [summary()]
  def summaries(track_id) do
    live()
    |> where([p], p.track_id == ^track_id)
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
      prompt: fragment("NULLIF(?, '')::jsonb->>'prompt'", p.payload),
      image_count:
        fragment("COALESCE(jsonb_array_length(NULLIF(?, '')::jsonb->'images'), 0)", p.payload)
    })
    |> Repo.all()
  end

  @doc """
  Move a row to `status` with `error`, unless it is already done.

  The id stays behind as a receipt for retried HTTP requests; a `:sent` or
  `:cancelled` row releases its payload. Nothing here checks who is asking:
  the server calls it on rows it is delivering, `cancel/3` and `retry/3`
  call it inside a transaction that established the person's right to.
  """
  @spec set_status(String.t(), Item.status(), String.t() | nil) :: :ok
  def set_status(id, status, error \\ nil) do
    payload_update = if status in @done, do: [payload: ""], else: []

    {_count, tracks} =
      Item
      |> where([p], p.id == ^id and p.status not in ^@done)
      # Nothing to tell anyone when the row already says this. The queue
      # server re-parks its head every two seconds while a machine is waking
      # or Fountain is unreachable, and every publish makes each open track
      # page re-read its transcript from Fountain -- so an unguarded write
      # turns a 15-second poll into a 2-second one against a dependency that
      # is already failing, per viewer, for as long as the outage lasts.
      |> where([p], p.status != ^status or fragment("? IS DISTINCT FROM ?", p.error, ^error))
      |> select([p], p.track_id)
      |> Repo.update_all(set: [status: status, error: error] ++ payload_update)

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
      |> Repo.update_all(set: [status: :sent, error: nil, payload: ""])

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
    |> Repo.update_all(set: [status: :cancelled, payload: "", error: nil])

    publish_queue(track_id)
  end

  # ── plumbing ──────────────────────────────────────────────────────────

  defp validate_request_id(id) when is_binary(id) do
    if Regex.match?(~r/^[a-zA-Z0-9-]{16,80}$/, id), do: :ok, else: request_id_required()
  end

  defp validate_request_id(_id), do: request_id_required()

  defp request_id_required,
    do:
      {:error,
       {:unprocessable, "request_id_required", "Send a unique request id with this prompt."}}

  # Inside the transaction. The track row is locked so two saves for one
  # track cannot both pass the cap; the unique index on id covers the
  # receipt. Returns the row and whether this call inserted it.
  defp enqueue_locked(track_id, user_id, author_login, id, payload) do
    lock_track!(track_id)

    case get(id) do
      %Item{track_id: ^track_id, user_id: ^user_id} = existing ->
        {existing, false}

      %Item{} ->
        Repo.rollback({:conflict, "request_id_used", "Use a new request id."})

      nil ->
        if waiting_count(track_id) >= @max_waiting do
          Repo.rollback(
            {:conflict, "queue_full",
             "This track already has #{@max_waiting} saved prompts. Cancel one or wait for it to run."}
          )
        end

        {insert(track_id, user_id, author_login, id, encode(payload)), true}
    end
  end

  defp lock_track!(track_id) do
    Track
    |> where([t], t.id == ^track_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil -> Repo.rollback(:not_found)
      %Track{} = track -> track
    end
  end

  defp waiting_count(track_id),
    do: live() |> where([p], p.track_id == ^track_id) |> Repo.aggregate(:count)

  defp encode(payload) do
    encoded =
      Jason.encode!(%{
        prompt: Map.get(payload, :prompt) || Map.get(payload, "prompt") || "",
        images: Map.get(payload, :images) || Map.get(payload, "images") || []
      })

    if byte_size(encoded) > @max_payload_bytes do
      Repo.rollback(
        {:unprocessable, "prompt_too_large",
         "This prompt has too many image bytes. Send fewer images."}
      )
    end

    encoded
  end

  defp insert(track_id, user_id, author_login, id, encoded) do
    %Item{}
    |> Item.changeset(%{
      id: id,
      track_id: track_id,
      user_id: user_id,
      author_login: author_login,
      payload: encoded
    })
    |> Repo.insert!()
  end

  defp cancel_locked(id, track_id, role, user) do
    with {:ok, row} <- lock_row(id, track_id),
         :ok <- require_sender_or_owner(row, role, user, "cancel"),
         :ok <- refuse_if(row.status in [:sending, :sent], already_sending()) do
      set_status(id, :cancelled)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp retry_locked(id, track, role, user) do
    with {:ok, row} <- lock_row(id, track.id),
         :ok <- refuse_if(not is_nil(track.closed_at), :not_found),
         :ok <- require_sender_or_owner(row, role, user, "resend"),
         :ok <- refuse_if(row.status not in [:failed, :unconfirmed], not_failed()) do
      set_status(id, :queued)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp already_sending,
    do:
      {:conflict, "already_sending",
       "This prompt is already being delivered. Stop the turn instead."}

  defp not_failed, do: {:conflict, "not_failed", "This prompt is not waiting for a retry."}

  defp refuse_if(true, reason), do: {:error, reason}
  defp refuse_if(false, _reason), do: :ok

  # The row, locked for the rest of the transaction, if it is on this track.
  defp lock_row(id, track_id) do
    Item
    |> where([p], p.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %Item{track_id: ^track_id} = row -> {:ok, row}
      _ -> {:error, :not_found}
    end
  end

  defp require_sender_or_owner(row, role, %User{id: user_id}, what) do
    if role == :owner or row.user_id == user_id,
      do: :ok,
      else: {:error, {:forbidden, "Only the sender or project owner can #{what} this prompt."}}
  end

  defp live, do: where(Item, [p], p.status not in ^@done)

  defp maybe_on_track(query, nil), do: query
  defp maybe_on_track(query, track_id), do: where(query, [p], p.track_id == ^track_id)

  # The panel re-reads a track's queue on this. Publishing is by project,
  # which the row does not carry; one read of the track finds it.
  defp publish_queue(track_id) do
    case Repo.get(Track, track_id) do
      %Track{project_id: project_id} -> Hub.publish(project_id, :queue, track_id: track_id)
      nil -> :ok
    end
  end
end
