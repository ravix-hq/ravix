defmodule Ravix.Presence do
  @moduledoc """
  Who is looking at a track right now, and who is mid-sentence.

  Two facts with the same shape and very different lifetimes, which is the
  whole design here:

    **Watching** lasted 45 seconds over HTTP and was refreshed by a heartbeat,
    because a stateless request had no other way to know a tab was still
    open. A LiveView is a process, so watching is now the process itself: a
    page tracks itself on the track's topic when it opens the track, and the
    tracker notices the moment it goes away, whether by navigation, a closed
    tab or a dropped socket. Nothing lingers for three quarters of a minute
    and nothing needs a timer to notice a lapse.

    **Typing** lasts 3 seconds and is refreshed by keystrokes. It has to be
    *ungenerous*: "Ana is typing..." left up after Ana wandered off is worse
    than no indicator at all, because it is the one signal people wait on
    before sending something themselves. A pulse rather than a state, so a
    browser that stops mid-word stops claiming to be typing without having to
    apologise for it, which a start/stop protocol could not manage.

  `Phoenix.Presence` over `Ravix.PubSub`, one topic per track. Every change
  to a track's room (a join, a leave, a typing pulse) reaches `handle_metas/4`
  in the presence server, which publishes the whole set as a `here` event on
  the project's hub topic (`shared/api.ts` `ProjectEvent`), and schedules one
  more frame for when the newest typing pulse lapses. Published every time
  rather than only on change: a frame is small, and comparing sets to save
  one is more code than it saves.

  Nothing here is persisted, and nothing should be: presence that survived a
  restart would be a list of people who are not there.

  The TypeScript scoped each `here` frame to an audience (the owner, the
  project's members and the track's own members) so an event naming a track
  did not tell a stranger the track exists. `Ravix.Hub` fans out by project,
  so the subscriber does that filtering: a page keeps a `here` frame only for
  a track it is already allowed to list. The frame carries logins, names and
  avatars and nothing else.
  """

  use Phoenix.Presence, otp_app: :ravix, pubsub_server: Ravix.PubSub

  alias Ravix.Accounts.User
  alias Ravix.Hub
  alias Ravix.Presence.Watcher

  @typing_ttl_ms 3_000

  @typedoc "Somebody with a track open right now; see `Ravix.Presence.Watcher`."
  @type presence :: Watcher.t()

  @typedoc """
  What a heartbeat reports. `:watching` is the composer's timer saying the
  page is still open; `:typing` is a keystroke. The two arrive
  independently, which is why they are named rather than flagged: a
  `beat(..., false)` read as cancelling a typing pulse, and it does not.
  """
  @type activity :: :typing | :watching

  @doc "How long a typing pulse stands."
  @spec typing_ttl_ms() :: pos_integer()
  def typing_ttl_ms, do: @typing_ttl_ms

  @doc "The presence topic for a track."
  @spec topic(String.t()) :: String.t()
  def topic(track_id), do: "presence:track:" <> track_id

  @doc """
  A heartbeat from the calling process: I am here, and possibly typing.

  The first beat from a process tracks it in the track's room; later beats
  update its metadata. A heartbeat that is not a typing pulse must not cancel
  one that is: the composer pings on a timer and on keystrokes independently,
  and the slower of the two arriving second would blink the indicator off.
  Returns who is in the room now, the caller included.
  """
  @spec beat(String.t(), String.t(), User.t(), activity()) :: [presence()]
  def beat(track_id, project_id, %User{} = user, activity)
      when activity in [:typing, :watching] do
    now = now_ms()
    topic = topic(track_id)

    meta = fn existing ->
      %{
        project_id: project_id,
        login: user.login,
        name: user.name,
        avatar_url: user.avatar_url,
        typing_until:
          if(activity == :typing,
            do: now + @typing_ttl_ms,
            else: Map.get(existing, :typing_until, 0)
          )
      }
    end

    case update(self(), topic, user.id, meta) do
      {:ok, _ref} -> :ok
      {:error, :nopresence} -> {:ok, _ref} = track(self(), topic, user.id, meta.(%{}))
    end

    present(track_id, now)
  end

  @doc """
  Somebody closing a track, rather than lapsing out of it.

  Worth having as well as the process lifetime: switching tracks in one page
  is the one moment we genuinely know, and a name in the corner of a
  colleague's screen that belongs to somebody now reading another track is
  exactly the kind of small wrongness that makes presence feel broken.
  """
  @spec leave(String.t(), String.t()) :: :ok
  def leave(track_id, user_id), do: untrack(self(), topic(track_id), user_id)

  @doc "Who is on a track now, sorted by login so the row never reshuffles, self included."
  @spec present(String.t(), integer()) :: [presence()]
  def present(track_id, now \\ now_ms()) do
    track_id |> topic() |> list() |> presences_of(now)
  end

  # ── the presence server's side ────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_metas("presence:track:" <> track_id, diff, presences, state) do
    presences = Map.new(presences, fn {id, metas} -> {id, %{metas: metas}} end)
    now = now_ms()
    here = presences_of(presences, now)

    # The room may have just emptied, in which case the only meta that still
    # knows the project is the one that left. An empty set is still news.
    case project_id_of(presences) || project_id_of(Map.get(diff, :leaves, %{})) do
      nil ->
        {:ok, Map.delete(state, track_id)}

      project_id ->
        publish(project_id, track_id, here)

        if presences == %{},
          do: {:ok, Map.delete(state, track_id)},
          else: {:ok, schedule_lapse(state, track_id, project_id, presences, now)}
    end
  end

  def handle_metas(_topic, _diff, _presences, state), do: {:ok, state}

  # One delayed frame per typing window, so "typing" goes out when the pulse
  # lapses even though no request arrives to say so. A pulse that extends the
  # window past what is scheduled schedules again; the earlier frame still
  # goes out, and says the truth as of that moment.
  defp schedule_lapse(state, track_id, project_id, presences, now) do
    latest =
      presences
      |> Enum.flat_map(fn {_key, %{metas: metas}} ->
        Enum.map(metas, &Map.get(&1, :typing_until, 0))
      end)
      |> Enum.max(fn -> 0 end)

    if latest > now and latest > Map.get(state, track_id, 0) do
      delay = latest - now + 1

      Task.Supervisor.start_child(Ravix.TaskSupervisor, fn ->
        Process.sleep(delay)
        publish(project_id, track_id, present(track_id))
      end)

      Map.put(state, track_id, latest)
    else
      state
    end
  end

  # Local, not cluster-wide (#19). Every instance runs `handle_metas/4` on the
  # same diff, so a cluster-wide broadcast from here would reach each reader once
  # per instance -- measured at three frames for one change on two nodes. Each
  # instance serving its own readers gets everyone exactly one, and the frame is
  # the whole room either way, because `list/1` is cluster-wide.
  defp publish(project_id, track_id, here) do
    Hub.publish_local(project_id, :here, track_id: track_id, present: here)
  end

  defp project_id_of(presences) do
    Enum.find_value(presences, fn {_key, %{metas: metas}} ->
      Enum.find_value(metas, &Map.get(&1, :project_id))
    end)
  end

  # Several metas per person (two tabs) are one entry: typing if any of them is.
  defp presences_of(presences, now) do
    presences
    |> Enum.map(fn {_key, %{metas: [first | _] = metas}} ->
      %Watcher{
        login: first.login,
        name: first.name,
        avatar_url: first.avatar_url,
        typing: Enum.any?(metas, &(Map.get(&1, :typing_until, 0) > now))
      }
    end)
    |> Enum.sort_by(& &1.login)
  end

  defp now_ms, do: System.system_time(:millisecond)
end
