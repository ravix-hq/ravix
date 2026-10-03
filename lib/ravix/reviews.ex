defmodule Ravix.Reviews do
  @moduledoc """
  Persistent human diff discussions. No agent prompts, transcript comments or
  GitHub writes. Track readers may discuss and resolve, just as they may post
  human transcript notes; machine write permission is not needed to discuss.
  Every call establishes track access before any row or provider work.
  """
  alias Ravix.Accounts.{Access, User}
  alias Ravix.Reviews.{Anchor, Discussion, Message, Store}
  alias Ravix.Tracks

  @type reason :: Tracks.reason() | Ecto.Changeset.t()

  @spec list(User.t(), String.t()) :: {:ok, [Discussion.t()]} | {:error, reason()}
  def list(%User{} = user, track_id) do
    with {:ok, _} <- Access.track_access(user, track_id), do: {:ok, Store.list(track_id)}
  end

  @doc "Re-read the authoritative diff, reject stale coordinates, then persist atomically."
  @spec open(User.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, Discussion.t()} | {:error, reason()}
  def open(%User{} = user, track_id, anchor, body, opts \\ []) do
    with {:ok, _} <- Access.track_access(user, track_id),
         {:ok, diff} <- Tracks.diff(user, track_id),
         {:ok, position} <- Anchor.locate(diff, anchor),
         # The provider read may have waited while membership changed.
         {:ok, access} <- Access.track_access(user, track_id),
         :ok <- session(user, opts),
         {:ok, discussion} <-
           Store.create(
             Map.merge(position, %{track_id: track_id, revision: Anchor.revision(diff)}),
             user.id,
             body
           ) do
      publish(access, track_id)
      {:ok, discussion}
    end
  end

  @spec reply(User.t(), String.t(), String.t(), String.t()) ::
          {:ok, Message.t()} | {:error, reason()}
  def reply(%User{} = user, track_id, id, body) do
    with {:ok, access} <- Access.track_access(user, track_id),
         {:ok, discussion} <- discussion(track_id, id),
         {:ok, message} <- Store.reply(discussion, user.id, body) do
      publish(access, track_id)
      {:ok, message}
    end
  end

  @spec resolve(User.t(), String.t(), String.t(), boolean()) ::
          {:ok, Discussion.t()} | {:error, reason()}
  def resolve(%User{} = user, track_id, id, resolved) when is_boolean(resolved) do
    with {:ok, access} <- Access.track_access(user, track_id),
         {:ok, discussion} <- discussion(track_id, id),
         {:ok, discussion} <- Store.resolve(discussion, resolved) do
      publish(access, track_id)
      {:ok, discussion}
    end
  end

  def resolve(%User{} = user, track_id, _id, _resolved) do
    with {:ok, _} <- Access.track_access(user, track_id),
         do: {:error, {:unprocessable, "review_resolution", "Choose resolve or reopen."}}
  end

  defp session(user, opts) do
    case Keyword.fetch(opts, :session_hash) do
      :error ->
        :ok

      {:ok, hash} ->
        case Ravix.Accounts.session_user(hash) do
          %{id: id} when id == user.id -> :ok
          _ -> {:error, :unauthenticated}
        end
    end
  end

  defp discussion(track_id, id) do
    case Store.get(track_id, id) do
      nil -> {:error, :not_found}
      discussion -> {:ok, discussion}
    end
  end

  defp publish(access, track_id),
    do: Ravix.Hub.publish(access.project.id, :review, track_id: track_id)
end
