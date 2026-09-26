defmodule Ravix.PromptQueue do
  @moduledoc """
  Accepted prompts awaiting delivery, which must outlive the browser that
  submitted them.

  Every prompt is saved here before the caller is told "saved". Text and
  attached images stay while another turn runs; closing a tab, changing
  tracks, or restarting the server does not discard waiting work.
  `Ravix.PromptQueue.Server` delivers the first live row per track to
  Fountain when the conversation is idle.

  The three functions here are the ones a person calls: `list/2`, `cancel/3`
  and `retry/3` each go through `Ravix.Accounts.Access.track_access/2` first.
  Everything else is `Ravix.PromptQueue.Store` -- the worker's half, which
  takes ids because at the moment a prompt is finally delivered there is no
  caller left to take a user from.

  Every change to a track's queue publishes a `"queue"` event on the
  project's `Ravix.Hub` topic so the saved-prompts panel re-reads it; the
  TypeScript polled instead. That publishing lives with the rows, in the
  store, so a change cannot be made without it.
  """

  alias Ravix.Accounts.{Access, User}
  alias Ravix.{Hub, Repo}
  alias Ravix.PromptQueue.{Store, View}

  @type reason ::
          :not_found
          | {:forbidden, String.t()}
          | {:conflict, String.t(), String.t()}
          | {:unprocessable, String.t(), String.t()}

  # ── the person's side ─────────────────────────────────────────────────

  @doc "The waiting prompts on a track, as the saved-prompts panel shows them."
  @spec list(User.t(), String.t(), String.t() | nil) :: {:ok, [View.t()]} | {:error, reason()}
  def list(%User{} = user, track_id, thread_id \\ nil) do
    with {:ok, %{role: role, thread: thread}} <- Access.thread_access(user, track_id, thread_id) do
      {:ok, Store.summaries(track_id, thread.id) |> Enum.map(&present(&1, role, user))}
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
    with {:ok, %{role: role, project: project}} <- Access.track_access(user, track_id),
         {:ok, :ok} <- Repo.transaction(fn -> cancel_locked(id, track_id, role, user) end) do
      # The Store hint is inside this transaction. Repeat it after commit so
      # wait_task on another node cannot consume only the pre-commit state.
      Hub.publish(project.id, :queue, track_id: track_id)
    end
  end

  @doc "Send a refused or unconfirmed prompt again, explicitly. Same rule of who may as `cancel/3`."
  @spec retry(User.t(), String.t(), String.t()) :: :ok | {:error, reason()}
  def retry(%User{} = user, track_id, id) do
    with {:ok, %{role: role, track: track, project: project}} <-
           Access.track_access(user, track_id),
         {:ok, :ok} <- Repo.transaction(fn -> retry_locked(id, track, role, user) end) do
      Hub.publish(project.id, :queue, track_id: track_id)
    end
  end

  @doc "A `QueuedPrompt` from a summary, for `role` and the person looking."
  @spec present(Store.summary(), :owner | :member, User.t()) :: View.t()
  def present(row, role, %User{id: user_id}) do
    %View{
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

  # ── plumbing ──────────────────────────────────────────────────────────

  defp cancel_locked(id, track_id, role, user) do
    with {:ok, row} <- Store.lock_row(id, track_id),
         :ok <- require_sender_or_owner(row, role, user, "cancel"),
         :ok <- refuse_if(row.status in [:sending, :sent], already_sending()) do
      Store.set_status(id, :cancelled)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp retry_locked(id, track, role, user) do
    with {:ok, row} <- Store.lock_row(id, track.id),
         :ok <- refuse_if(not is_nil(track.closed_at), :not_found),
         :ok <- require_sender_or_owner(row, role, user, "resend"),
         :ok <- refuse_if(row.status not in [:failed, :unconfirmed], not_failed()) do
      Store.set_status(id, :queued)
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

  defp require_sender_or_owner(row, role, %User{id: user_id}, what) do
    if role == :owner or row.user_id == user_id,
      do: :ok,
      else: {:error, {:forbidden, "Only the sender or project owner can #{what} this prompt."}}
  end
end
