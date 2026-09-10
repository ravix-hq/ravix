defmodule RavixWeb.Live.Guard do
  @moduledoc """
  May this page still do what it is doing? Asked on every message, answered
  without reading a row.

  Mount-time authentication is not enough, and the pages have always known
  it: both attach hooks that re-establish who is asking before every event,
  message and async result. What they did was re-run the whole of it --
  `Ravix.Accounts.session_user/1`, and on a track
  `Ravix.Accounts.Access.track_access/2` and the session again. Six queries
  a message, and the messages are not rare: a transcript arrives as a stream
  of them while an agent is talking, and the fifteen-second tick adds twenty
  more per open page whether anybody is there or not.

  Re-deriving the answer that often is not what makes it correct. What makes
  it correct is noticing the three things that can *change* it, and each of
  those announces itself:

    * **The session runs out.** That is a time, written on the row, and it
      does not move. Read once at mount and compared against the clock
      afterwards, which costs nothing.

    * **The session is ended somewhere else.** `Ravix.Accounts.end_session/1`
      says so on the session's own topic, so a page hears it and goes at
      once -- sooner than it used to, since before this a page nobody was
      touching kept its screen until its next message, which might be
      minutes.

    * **Membership changes, or the track closes, or the project is
      archived.** Every one of those publishes `:people` or `:tracks` on the
      project's hub, which the page is already subscribed to. The event is
      what marks the held answer stale, so the re-read happens on the
      message that carries the news rather than on the one after it.

  This is the arrangement `Ravix.Tracks.Follower` already documents as the
  contract for the transcript stream: *"a page subscribed to a track
  re-checks `track_access/2` when the project's hub says its people or
  tracks changed, and unsubscribes if it is no longer allowed."*

  ## The backstop

  PubSub is best-effort, and Ravix runs on more than one instance (ADR
  0003), so a partition can eat the message that would have marked the
  answer stale. A held answer therefore also expires on its own after
  `ttl_ms/0`, and the page re-reads. That is the whole of what this changes
  about the guarantee: a removal that used to be seen on the very next
  message is now seen at once in the ordinary case, and within fifteen
  seconds in the case where the notice went missing.

  It is worth being clear about what was never resting on these hooks. Every
  context call re-establishes access for itself -- `Ravix.Tracks.get/2`,
  `Ravix.Tracks.prompt/3`, `Ravix.People.add/3`, all of them go through
  `Ravix.Accounts.Access` -- so no *action* is authorised by a held answer.
  What the hooks protect is the page itself: getting somebody off a track
  they have been removed from, and stopping the transcript stream, which is
  the one thing a page receives without asking a context for it.
  """

  alias Ravix.Accounts
  alias Ravix.Hub.Event

  @ttl_ms 15_000

  @typedoc """
  What the page holds between reads.

  `expires_at` is the session's own, `verified_at_ms` is monotonic so a
  clock change cannot extend it, and `stale?` is set by the events above.
  """
  @type t :: %__MODULE__{
          hash: String.t() | nil,
          expires_at: DateTime.t() | nil,
          verified_at_ms: integer(),
          stale?: boolean()
        }

  defstruct [:hash, :expires_at, :verified_at_ms, stale?: false]

  @doc "How long a held answer stands when nothing has said otherwise."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc """
  A fresh answer for a session that has just been read.

  `expires_at` is the session's; `nil` for a page with nobody signed in,
  which then has nothing to hold and re-reads whenever it is asked.
  """
  @spec new(String.t() | nil, DateTime.t() | nil) :: t()
  def new(hash, expires_at) do
    %__MODULE__{
      hash: hash,
      expires_at: expires_at,
      verified_at_ms: System.monotonic_time(:millisecond),
      stale?: false
    }
  end

  @doc """
  Whether the held answer still stands, without reading anything.

  False when there is no answer to hold, when something said it was stale,
  when the session's own expiry has passed, or when it has simply been long
  enough. A false here is "ask again", not "refuse": the caller re-reads and
  decides.
  """
  @spec holds?(t() | nil) :: boolean()
  def holds?(%__MODULE__{stale?: true}), do: false
  def holds?(%__MODULE__{expires_at: nil}), do: false
  def holds?(%__MODULE__{hash: nil}), do: false

  def holds?(%__MODULE__{expires_at: expires_at, verified_at_ms: at}) do
    System.monotonic_time(:millisecond) - at < @ttl_ms and
      DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  def holds?(nil), do: false

  @doc "Mark the held answer as needing a re-read before it is trusted again."
  @spec stale(t() | nil) :: t() | nil
  def stale(%__MODULE__{} = guard), do: %{guard | stale?: true}
  def stale(nil), do: nil

  @doc """
  What a message means for a held answer.

  Called from the `handle_info` hook, which sees the message *before* the
  page does, so a re-read happens on the news rather than on the message
  after it.

  A session ending is the one thing that can take a session away. For a page
  that also holds an answer about a **track**, `track_id` names it, and
  `:people` or `:tracks` on the project's hub marks that answer stale --
  every way access to a track goes is one of those. Only when the event
  concerns that track, though: somebody being invited to a *sibling* branch
  cannot reach this page's access, and `Ravix.Hub.Event.concerns?/2` is
  already the question of whether it might. Everything else leaves the
  answer standing.
  """
  @spec observe(term(), t() | nil, String.t() | nil) :: t() | nil
  def observe(message, guard, track_id \\ nil)

  def observe({:session_ended, hash}, %__MODULE__{hash: hash} = guard, _track_id),
    do: stale(guard)

  def observe({:hub, %Event{name: name} = event}, guard, track_id)
      when name in [:people, :tracks] and is_binary(track_id),
      do: if(Event.concerns?(event, track_id), do: stale(guard), else: guard)

  def observe(_message, guard, _track_id), do: guard

  @doc """
  Read the session again, or say the held answer still stands.

  `{:ok, guard}` with a fresh answer, or `:error` when there is no live
  session behind it any more. A page holding an answer that still stands
  gets it back untouched and reads nothing.
  """
  @spec verify(t() | nil, String.t() | nil) :: {:ok, t()} | :error
  def verify(guard, hash) do
    cond do
      holds?(guard) ->
        {:ok, guard}

      is_nil(hash) ->
        :error

      true ->
        case Accounts.open_session(hash) do
          {:ok, _user, expires_at} -> {:ok, new(hash, expires_at)}
          :error -> :error
        end
    end
  end
end
