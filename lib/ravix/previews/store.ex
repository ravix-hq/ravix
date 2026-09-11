defmodule Ravix.Previews.Store do
  @moduledoc """
  The preview tables, `preview-store.ts` over the Ecto schemas.

  Four tables: a project's defaults, the preview row per track (see
  `Ravix.Previews.Row` for the document), the browser grants that let a
  preview host in, and the one agent grant per track that lets the helper
  script operate it. Nothing here checks who is asking; that is the
  context's job. What the store does own is port allocation: the partial
  unique index `preview_ports` on `(sprite, port)` decides, including
  across connections, and `allocate/3` retries when it loses that race.

  Times are milliseconds since the epoch, read from `Ravix.Clock`.
  """

  import Ecto.Query

  alias Ravix.Accounts.Session
  alias Ravix.Clock
  alias Ravix.Previews.{Preview, PreviewAgentGrant, PreviewDefault, PreviewGrant, Row}
  alias Ravix.Repo

  @first_port 20_000
  @last_port 29_999
  @allocate_attempts 8

  @typedoc "A browser grant: the hash of a ticket or preview cookie, tied to a Ravix session."
  @type grant :: %{
          hash: String.t(),
          track_id: String.t(),
          session_hash: String.t(),
          expires: integer(),
          kind: :ticket | :session
        }

  @typedoc "The helper's grant for one delivered turn."
  @type agent_grant :: %{
          hash: String.t(),
          track_id: String.t(),
          user_id: String.t(),
          conversation_id: String.t() | nil,
          prompt_id: String.t(),
          sandbox_id: String.t(),
          sprite: String.t(),
          expires: integer()
        }

  # ── defaults ─────────────────────────────────────────────────────────

  @doc "A project's default configuration, or nil."
  @spec defaults(String.t()) :: Row.config() | nil
  def defaults(project_id) do
    case Repo.get(PreviewDefault, project_id) do
      nil -> nil
      %PreviewDefault{config: config} -> config
    end
  end

  @doc "Save (or with nil, clear) a project's default configuration."
  @spec set_defaults(String.t(), Row.config() | nil) :: :ok
  def set_defaults(project_id, nil) do
    Repo.delete_all(from d in PreviewDefault, where: d.project_id == ^project_id)
    :ok
  end

  def set_defaults(project_id, config) do
    %PreviewDefault{}
    |> PreviewDefault.changeset(%{project_id: project_id, config: config})
    |> Repo.insert!(
      on_conflict: [set: [config: config]],
      conflict_target: :project_id
    )

    :ok
  end

  # ── rows ─────────────────────────────────────────────────────────────

  @doc "A track's preview row, or nil."
  @spec get(String.t()) :: Row.t() | nil
  def get(track_id) do
    case Repo.get(Preview, track_id) do
      nil -> nil
      %Preview{} = preview -> Row.from_preview(preview)
    end
  end

  @doc "The row behind a preview hostname (the first label of the host), or nil."
  @spec by_host(String.t()) :: Row.t() | nil
  def by_host(hostname) do
    case Repo.get_by(Preview, hostname: hostname) do
      nil -> nil
      %Preview{} = preview -> Row.from_preview(preview)
    end
  end

  @doc "Every preview row; what the reconciler walks."
  @spec all() :: [Row.t()]
  def all do
    Preview |> Repo.all() |> Enum.map(&Row.from_preview/1)
  end

  @doc "Every row of a project's tracks, whatever their state."
  @spec of_project(String.t()) :: [Row.t()]
  def of_project(project_id) do
    # ownership: a store, and the join is on the track column its own rows
    # carry. The caller established the project before asking.
    Repo.all(
      from p in Preview,
        join: t in Ravix.Tracks.Track,
        on: t.id == p.track_id,
        where: t.project_id == ^project_id
    )
    |> Enum.map(&Row.from_preview/1)
  end

  @doc "A track's row, created stopped when it has none."
  @spec ensure(String.t()) :: Row.t()
  def ensure(track_id) do
    case get(track_id) do
      %Row{} = row ->
        row

      nil ->
        row = Row.new(track_id)

        case Repo.insert(changeset(row)) do
          {:ok, _} -> row
          # Lost the race to another process; theirs is the row.
          {:error, _changeset} -> get(track_id) || raise "preview row vanished for #{track_id}"
        end
    end
  end

  @doc """
  A track's row, held against concurrent writers for the rest of the
  transaction. Nil when the track has no row yet.
  """
  @spec lock(String.t()) :: Row.t() | nil
  def lock(track_id) do
    query = from p in Preview, where: p.track_id == ^track_id, lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> nil
      %Preview{} = preview -> Row.from_preview(preview)
    end
  end

  @doc """
  Set named fields on a track's row, leaving every other one alone.

  What a whole-record write could not do. Each writer here owns some fields
  and not others, and the record used to be written back entire: a caller
  that read nineteen fields, changed one, and wrote nineteen back reverted
  whatever had committed in between. That is exactly what happened to
  `Ravix.Previews.touch/1` -- a `publish_ready` landing between its read and
  its write went back to `:starting`, and the gateway kept sending the reader
  to the start page -- and the fix then was a `FOR UPDATE` read and a merge,
  because with one jsonb document there was nothing else to do.

  With columns there is: this is a single `UPDATE` of the named fields, and
  no lock, no re-read and no window. A row that does not exist yet is not an
  error; the answer is how many rows moved.

  It does not touch `sprite` or `port`, which the unique index owns and
  `allocate/3` is for.
  """
  @spec update(String.t(), keyword()) :: non_neg_integer()
  def update(track_id, changes) when is_list(changes) and changes != [] do
    {count, _} =
      Preview
      |> where([p], p.track_id == ^track_id)
      |> Repo.update_all(set: changes)

    count
  end

  @doc """
  Write a row, replacing what was there.

  Fails (with the changeset) when the port is taken on that sprite: the
  index owns allocation and this is where a loser finds out.
  """
  @spec save(Row.t()) :: :ok | {:error, Ecto.Changeset.t()}
  def save(%Row{} = row) do
    attrs = Row.to_attrs(row)

    case Repo.insert(changeset(row),
           on_conflict: [set: Map.to_list(attrs) ++ [row: Row.encode(row)]],
           conflict_target: :track_id
         ) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "`save/1` for callers that cannot be handing out a taken port."
  @spec save!(Row.t()) :: :ok
  def save!(%Row{} = row) do
    case save(row) do
      :ok ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  defp changeset(%Row{} = row) do
    Preview.changeset(%Preview{}, Map.put(Row.to_attrs(row), :row, Row.encode(row)))
  end

  @doc """
  Give a track a port on `sprite`, in a transaction: the lowest free one
  from 20000 to 29999. A row already holding a port on that sprite keeps
  it. Two allocations racing for the same port both read it as free; the
  unique index refuses one, and that one tries again.
  """
  @spec allocate(String.t(), String.t(), String.t()) ::
          {:ok, Row.t()} | {:error, :no_ports | Ecto.Changeset.t()}
  def allocate(track_id, sandbox_id, sprite), do: allocate(track_id, sandbox_id, sprite, 1)

  defp allocate(track_id, sandbox_id, sprite, attempt) do
    case Repo.transaction(fn -> reserve(track_id, sandbox_id, sprite) end) do
      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if attempt < @allocate_attempts and Keyword.has_key?(errors, :port),
          do: allocate(track_id, sandbox_id, sprite, attempt + 1),
          else: {:error, changeset}

      other ->
        other
    end
  end

  # Inside the transaction: keep a port already held on this sprite, else take the lowest free one.
  defp reserve(track_id, sandbox_id, sprite) do
    %Row{} = row = ensure(track_id)

    with false <- row.sprite == sprite and row.port != nil,
         {:ok, port} <- free_port(sprite),
         row = %Row{row | sprite: sprite, sandbox_id: sandbox_id, port: port, applied_config: nil},
         :ok <- save(row) do
      row
    else
      true -> row
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp free_port(sprite) do
    used =
      Repo.all(
        from p in Preview, where: p.sprite == ^sprite and not is_nil(p.port), select: p.port
      )

    case Enum.find(@first_port..@last_port, &(&1 not in used)) do
      nil -> {:error, :no_ports}
      port -> {:ok, port}
    end
  end

  # ── browser grants ───────────────────────────────────────────────────

  @doc "Store a grant, sweeping expired ones on the way."
  @spec grant(grant()) :: :ok | {:error, Ecto.Changeset.t()}
  def grant(grant) do
    now = Clock.now_ms()
    Repo.delete_all(from g in PreviewGrant, where: g.expires <= ^now)

    case Repo.insert(
           PreviewGrant.changeset(
             %PreviewGrant{},
             Map.take(grant, [:hash, :track_id, :session_hash, :expires, :kind])
           )
         ) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @typedoc """
  Whether reading a grant also spends it. A ticket is single-use, so the
  read that authorizes it must delete it; a session grant is read on every
  request and must survive being looked at.
  """
  @type disposition :: :peek | :consume

  @doc "An unexpired grant of `kind` on `track_id`, deleted on the way out when `:consume`."
  @spec get_grant(String.t(), String.t(), :ticket | :session, disposition()) :: grant() | nil
  def get_grant(hash, track_id, kind, disposition \\ :peek)
      when disposition in [:peek, :consume] do
    now = Clock.now_ms()

    query =
      from g in PreviewGrant,
        where:
          g.hash == ^hash and g.track_id == ^track_id and g.kind == ^kind and g.expires > ^now,
        select: g

    found =
      if disposition == :consume do
        {_count, rows} = Repo.delete_all(query)
        List.first(rows)
      else
        Repo.one(query)
      end

    found && present_grant(found)
  end

  @doc "Drop a track's browser grants, or only those of one user's sessions."
  @spec revoke(String.t(), String.t() | nil) :: :ok
  def revoke(track_id, user_id \\ nil) do
    query = from g in PreviewGrant, where: g.track_id == ^track_id

    query =
      if user_id,
        do:
          where(
            query,
            [g],
            g.session_hash in subquery(
              from s in Session, where: s.user_id == ^user_id, select: s.token_hash
            )
          ),
        else: query

    Repo.delete_all(query)
    :ok
  end

  defp present_grant(%PreviewGrant{} = g) do
    %{
      hash: g.hash,
      track_id: g.track_id,
      session_hash: g.session_hash,
      expires: g.expires,
      kind: g.kind
    }
  end

  # ── agent grants ─────────────────────────────────────────────────────

  @doc "Store the helper's grant for a track, replacing the last one and sweeping expired ones."
  @spec grant_agent(agent_grant()) :: :ok | {:error, Ecto.Changeset.t()}
  def grant_agent(grant) do
    now = Clock.now_ms()
    track_id = grant.track_id

    Repo.delete_all(
      from g in PreviewAgentGrant, where: g.expires <= ^now or g.track_id == ^track_id
    )

    attrs = %{
      hash: grant.hash,
      track_id: track_id,
      user_id: grant.user_id,
      expires: grant.expires,
      row: encode_agent_grant(grant)
    }

    case Repo.insert(PreviewAgentGrant.changeset(%PreviewAgentGrant{}, attrs)) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "The unexpired agent grant behind a token hash, or nil."
  @spec agent_grant(String.t()) :: agent_grant() | nil
  def agent_grant(hash) do
    now = Clock.now_ms()

    case Repo.one(from g in PreviewAgentGrant, where: g.hash == ^hash and g.expires > ^now) do
      nil -> nil
      %PreviewAgentGrant{row: row} -> decode_agent_grant(row)
    end
  end

  @doc "Drop a track's agent grant, or only one user's."
  @spec revoke_agent(String.t(), String.t() | nil) :: :ok
  def revoke_agent(track_id, user_id \\ nil) do
    query = from g in PreviewAgentGrant, where: g.track_id == ^track_id
    query = if user_id, do: where(query, [g], g.user_id == ^user_id), else: query
    Repo.delete_all(query)
    :ok
  end

  @agent_keys ~w(hash track_id user_id conversation_id prompt_id sandbox_id sprite expires)a

  defp encode_agent_grant(grant) do
    Map.new(@agent_keys, fn key -> {Atom.to_string(key), Map.get(grant, key)} end)
  end

  defp decode_agent_grant(row) do
    row = Row.normalize_keys(row)
    Map.new(@agent_keys, fn key -> {key, row[Atom.to_string(key)]} end)
  end
end
