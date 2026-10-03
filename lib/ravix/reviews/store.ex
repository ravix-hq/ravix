defmodule Ravix.Reviews.Store do
  @moduledoc "Row access behind Reviews' Access.track_access door."
  import Ecto.Query
  alias Ravix.Repo
  alias Ravix.Reviews.{Discussion, Message}

  def list(track_id) do
    Repo.all(
      from d in Discussion,
        where: d.track_id == ^track_id,
        order_by: [asc: d.inserted_at, asc: d.id]
    )
    |> preload()
  end

  def get(track_id, id) when is_binary(id),
    do: Repo.one(from d in Discussion, where: d.track_id == ^track_id and d.id == ^id)

  def get(_, _), do: nil

  def create(attrs, user_id, body) do
    discussion = Discussion.changeset(%Discussion{}, attrs)
    id = Ecto.Changeset.get_field(discussion, :id)
    message = Message.changeset(%Message{}, %{discussion_id: id, author_id: user_id, body: body})

    Repo.transaction(fn ->
      with {:ok, row} <- Repo.insert(discussion),
           {:ok, _} <- Repo.insert(message) do
        row
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, row} -> {:ok, preload(row)}
      {:error, reason} -> {:error, reason}
    end
  end

  def reply(discussion, user_id, body) do
    %Message{}
    |> Message.changeset(%{discussion_id: discussion.id, author_id: user_id, body: body})
    |> Repo.insert()
  end

  def resolve(discussion, resolved),
    do: discussion |> Ecto.Changeset.change(resolved: resolved) |> Repo.update()

  defp preload(rows) do
    messages = from m in Message, order_by: [asc: m.inserted_at, asc: m.id], preload: :author
    Repo.preload(rows, messages: messages)
  end
end
