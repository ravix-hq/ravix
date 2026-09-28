defmodule Ravix.Comments do
  @moduledoc """
  Comments: notes people leave on a thread for each other, never for the agent.

  A comment is a row in `thread_comments` and nothing else. It is not a
  prompt, is never queued, and nothing that builds a turn, the agent's
  context or the MCP `read_track` page reads this table. That last one is a
  decision rather than an omission: the Ravix MCP tools can be held by the
  track's own agent, and "never sent to the agent" is only true by
  construction if no tool an agent may call returns comments. A human-facing
  listing belongs here, behind the same door, when one is wanted.

  Anybody who can reach the thread may read and post; only the author may
  edit or delete, and deleting is soft so the transcript can say a comment
  was there. Every function takes the current user and goes through
  `Ravix.Accounts.Access.thread_access/3` first.

  Posting marks the thread unread for everybody else on it (see
  `Ravix.Tracks.list/3`, which reads `Store.activity/2`), and an `@login`
  naming somebody who can reach the track puts it in their Inbox. Mentions
  resolve against the people who can reach the track: the project's owner
  and members, the track's members and its creator, each put through
  `Access.track_access/2`, so a private track's outsiders cannot be named.
  Anything else stays text.
  """

  alias Ravix.Accounts.{Access, User}
  alias Ravix.Comments.{Comment, Store}
  alias Ravix.Hub

  @max_mentions 20
  @mention ~r/(?<![\w@\/`])@([A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38})/

  @typedoc "Everything a comment call can refuse with."
  @type reason :: :not_found | {:forbidden, String.t()} | Ecto.Changeset.t()

  @typedoc "Where a new comment sits: the page's last visible turn and newest event."
  @type anchor :: %{
          optional(:anchor_turn_id) => String.t() | nil,
          optional(:anchor_event_id) => integer() | nil
        }

  @typedoc "Somebody who can be named in a comment on a track."
  @type person :: %{login: String.t(), name: String.t() | nil, avatar_url: String.t() | nil}

  @doc "A thread's comments, oldest first. A deleted comment keeps its place and loses its body."
  @spec list(User.t(), String.t(), String.t() | nil) :: {:ok, [Comment.t()]} | {:error, reason()}
  def list(%User{} = user, track_id, thread_id) do
    with {:ok, %{thread: thread}} <- Access.thread_access(user, track_id, thread_id) do
      {:ok, Enum.map(Store.list(thread.id), &redact/1)}
    end
  end

  @doc """
  Post a comment on a thread. Never reaches the agent.

  `anchor` places it in the transcript; see `Ravix.Comments.Comment`.
  """
  @spec post(User.t(), String.t(), String.t() | nil, String.t(), anchor()) ::
          {:ok, Comment.t()} | {:error, reason()}
  def post(%User{} = user, track_id, thread_id, body, anchor \\ %{}) do
    with {:ok, %{track: track, project: project, thread: thread}} <-
           Access.thread_access(user, track_id, thread_id),
         {:ok, comment} <-
           %Comment{}
           |> Comment.create_changeset(%{
             track_id: track.id,
             thread_id: thread.id,
             author_id: user.id,
             body: body,
             conversation_id: thread.conversation_id,
             anchor_turn_id: anchor_turn(anchor[:anchor_turn_id]),
             anchor_event_id: anchor_event(anchor[:anchor_event_id])
           })
           |> Store.insert() do
      notify(comment, track, project)
      publish(project, comment)
      {:ok, comment}
    end
  end

  @doc "Change a comment's body. The author's alone; a new `@login` in it is notified."
  @spec edit(User.t(), String.t(), String.t(), String.t()) ::
          {:ok, Comment.t()} | {:error, reason()}
  def edit(%User{} = user, track_id, comment_id, body) do
    with {:ok, comment, %{track: track, project: project}} <- authored(user, track_id, comment_id),
         {:ok, comment} <- comment |> Comment.edit_changeset(%{body: body}) |> Store.update() do
      notify(comment, track, project)
      publish(project, comment)
      {:ok, comment}
    end
  end

  @doc "Delete a comment. The author's alone; the transcript keeps a placeholder."
  @spec delete(User.t(), String.t(), String.t()) :: {:ok, Comment.t()} | {:error, reason()}
  def delete(%User{} = user, track_id, comment_id) do
    with {:ok, comment, %{project: project}} <- authored(user, track_id, comment_id),
         {:ok, comment} <-
           comment |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Store.update() do
      publish(project, comment)
      {:ok, redact(comment)}
    end
  end

  @doc "The people a comment on this track may name, by login. The caller is left out."
  @spec mentionable(User.t(), String.t()) :: {:ok, [person()]} | {:error, reason()}
  def mentionable(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- Access.thread_access(user, track_id) do
      {:ok,
       track
       |> reachable(project)
       |> Enum.reject(&(&1.id == user.id))
       |> Enum.map(&%{login: &1.login, name: &1.name, avatar_url: &1.avatar_url})}
    end
  end

  @doc "The distinct logins a body names with `@login`, lowercased, at most #{@max_mentions}."
  @spec mentions(String.t()) :: [String.t()]
  def mentions(body) when is_binary(body) do
    @mention
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [login] -> String.downcase(login) end)
    |> Enum.uniq()
    |> Enum.take(@max_mentions)
  end

  # The comment, if this person may reach its thread and wrote it. Somebody
  # else's comment is refused rather than hidden: they can read it anyway.
  defp authored(user, track_id, comment_id) do
    with %Comment{deleted_at: nil, track_id: ^track_id} = comment <- Store.get(comment_id),
         {:ok, access} <- Access.thread_access(user, track_id, comment.thread_id) do
      if comment.author_id == user.id,
        do: {:ok, comment, access},
        else: {:error, {:forbidden, "Only the author can change this comment."}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  defp notify(comment, track, project) do
    case mentions(comment.body) do
      [] ->
        :ok

      logins ->
        named = MapSet.new(logins)

        ids =
          track
          |> reachable(project)
          |> Enum.filter(&(&1.id != comment.author_id and MapSet.member?(named, lower(&1.login))))
          |> Enum.map(& &1.id)

        Store.mention(comment.id, ids, DateTime.utc_now())
    end
  end

  # Candidates from the membership rows, each put through the door itself, so
  # a closed track, a private track's outsider or a revoked creator is never
  # offered and never notified.
  defp reachable(track, project) do
    track
    |> Store.candidates(project)
    |> Enum.filter(&match?({:ok, _}, Access.track_access(&1, track.id)))
  end

  defp publish(project, comment),
    do:
      Hub.publish(project.id, :comment,
        track_id: comment.track_id,
        thread_id: comment.thread_id,
        user_id: comment.author_id
      )

  defp redact(%Comment{deleted_at: nil} = comment), do: comment
  defp redact(comment), do: %{comment | body: nil}

  defp lower(nil), do: ""
  defp lower(login), do: String.downcase(login)

  defp anchor_turn(id) when is_binary(id) and byte_size(id) in 1..200, do: id
  defp anchor_turn(_), do: nil

  defp anchor_event(id) when is_integer(id) and id >= 0, do: id
  defp anchor_event(_), do: nil
end
