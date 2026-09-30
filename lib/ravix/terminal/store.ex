defmodule Ravix.Terminal.Store do
  @moduledoc """
  The `terminal_tabs` rows, with nobody's permission established.

  Every function takes ids and touches the table; none asks who is calling.
  `Ravix.Terminal` establishes track access before it reaches one of these,
  and `Ravix.Terminal.Shell` --- the process holding a tab's socket --- is
  started only by it, for a tab it has already checked, and writes back only
  that tab's own row.

  Every read and write names the person as well as the tab, so a tab id
  guessed or replayed from another session answers nothing.
  """

  import Ecto.Query

  alias Ravix.Repo
  alias Ravix.Terminal.Tab

  # Unique on `(track_id, user_id, number)`: two opens racing for the same
  # lowest free number lose to the index, and the loser tries the next.
  @insert_attempts 4

  @doc "A person's tabs on a track, in the order they are numbered."
  @spec list(String.t(), String.t()) :: [Tab.t()]
  def list(track_id, user_id) do
    Repo.all(
      from(t in Tab,
        where: t.track_id == ^track_id and t.user_id == ^user_id,
        order_by: [asc: t.number]
      )
    )
  end

  @doc "One of a person's tabs on a track, or nil."
  @spec get(String.t(), String.t(), String.t()) :: Tab.t() | nil
  def get(track_id, user_id, id) do
    Repo.one(
      from(t in Tab, where: t.id == ^id and t.track_id == ^track_id and t.user_id == ^user_id)
    )
  end

  @doc "How many tabs a person has open on a track."
  @spec count(String.t(), String.t()) :: non_neg_integer()
  def count(track_id, user_id) do
    Repo.aggregate(
      from(t in Tab, where: t.track_id == ^track_id and t.user_id == ^user_id),
      :count
    )
  end

  @doc "A new tab on `sprite`, numbered with the lowest number the person has free."
  @spec insert(String.t(), String.t(), String.t()) :: {:ok, Tab.t()} | {:error, term()}
  def insert(track_id, user_id, sprite), do: insert(track_id, user_id, sprite, @insert_attempts)

  defp insert(_track_id, _user_id, _sprite, 0), do: {:error, :conflict}

  defp insert(track_id, user_id, sprite, attempts) do
    taken = MapSet.new(list(track_id, user_id), & &1.number)
    number = Enum.find(Stream.iterate(1, &(&1 + 1)), &(not MapSet.member?(taken, &1)))

    %Tab{}
    |> Tab.changeset(%{track_id: track_id, user_id: user_id, sprite: sprite, number: number})
    |> Repo.insert()
    |> case do
      {:ok, tab} ->
        {:ok, tab}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :track_id) and unique?(errors[:track_id]),
          do: insert(track_id, user_id, sprite, attempts - 1),
          else: {:error, changeset}
    end
  end

  defp unique?({_message, opts}), do: opts[:constraint] == :unique

  @doc "Record the Sprites session a tab's shell runs as."
  @spec put_session(String.t(), String.t(), String.t()) :: :ok
  def put_session(id, user_id, session_id) do
    Repo.update_all(from(t in Tab, where: t.id == ^id and t.user_id == ^user_id),
      set: [session_id: session_id]
    )

    :ok
  end

  @doc "Forget a tab. True when there was one to forget."
  @spec delete(String.t(), String.t()) :: boolean()
  def delete(id, user_id) do
    {n, _} = Repo.delete_all(from(t in Tab, where: t.id == ^id and t.user_id == ^user_id))
    n > 0
  end
end
