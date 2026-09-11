defmodule Ravix.Previews.Reconciler do
  @moduledoc """
  The fifteen-second tick of `server/previews.ts`: the database says what
  each preview should be, and this makes it so.

  For every row, in parallel across tracks and never twice for one track:

    * a track that closed, a project that was archived, or a row marked
      for cleanup, still holding a sprite: remove its service (`stop_service`
      with cleanup), which is also how a cleanup that failed is retried
    * a stop that never reached Sprites (`stop_pending`): stop again
    * a running preview nobody has touched for five minutes: stop it
    * a running preview whose viewing lease is live, and no operation in
      flight: make sure it is running (which refreshes the sprite's
      activity task, notices a replaced machine, and after a restart of
      Ravix restores what the database says should be up)

  A preview whose lease expired but whose idle time has not is left alone:
  no health polling of an idle machine. Failed startups have `desired`
  set to stopped and so are never retried here; only an explicit open or
  restart tries again.

  `tick/0` runs one pass synchronously, for tests and for the process.
  Nothing happens at all while `Ravix.Previews.unavailable/0` says so.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Ravix.Clock
  alias Ravix.Previews
  alias Ravix.Previews.{Row, Server, Store}
  alias Ravix.Projects.Project
  alias Ravix.Repo
  alias Ravix.Tracks.Track

  @interval_ms 15_000
  @row_timeout_ms 5 * 60_000

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "One reconciliation pass over every preview row, waited for."
  @spec tick() :: :ok
  def tick do
    if Previews.unavailable() == nil do
      rows = Store.all()

      Ravix.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(with_context(rows), &reconcile/1,
        ordered: false,
        timeout: @row_timeout_ms,
        on_timeout: :kill_task
      )
      |> Stream.run()
    end

    :ok
  end

  # Every row's track and project, read for the whole pass rather than for
  # each row.
  #
  # A pass asks the same two questions of every preview -- has this track
  # closed, has this project been archived -- and asked one row at a time
  # that was two queries each, on a fifteen-second timer, for every preview
  # in the deployment. Rows of the same project were reading that project
  # over again.
  #
  # The pass is a snapshot: a track that closes while it runs is reconciled
  # on the next one, fifteen seconds later, which is the same answer the
  # tick before it would have given.
  defp with_context(rows) do
    tracks =
      rows
      |> Enum.map(& &1.track_id)
      # ownership: the reconciler is a sweep, not a request -- it has no caller
      # to establish anything for. These are the tracks behind the preview rows
      # it just read, named so their project's machine can be checked.
      |> then(&Repo.all(from t in Track, where: t.id in ^&1))
      |> Map.new(&{&1.id, &1})

    projects =
      tracks
      |> Map.values()
      |> Enum.map(& &1.project_id)
      |> Enum.uniq()
      # ownership: as above -- a sweep with no caller, reading the projects
      # those tracks sit on so each preview can be checked against its machine.
      |> then(&Repo.all(from p in Project, where: p.id in ^&1))
      |> Map.new(&{&1.id, &1})

    Enum.map(rows, fn row ->
      track = Map.get(tracks, row.track_id)
      {row, track, track && Map.get(projects, track.project_id)}
    end)
  end

  @doc "What one row needs, as a pure decision (`:cleanup`, `:stop`, `:ensure` or `:leave`)."
  @spec decide(Row.t(), Track.t() | nil, Project.t() | nil, integer()) ::
          :cleanup | :stop | :ensure | :leave
  def decide(%Row{} = row, track, project, now) do
    cond do
      gone?(track, project) or row.cleanup -> if row.sprite, do: :cleanup, else: :leave
      row.stop_pending -> :stop
      row.desired != :running -> :leave
      true -> decide_running(row, now)
    end
  end

  defp gone?(track, project) do
    track == nil or track.closed_at != nil or project == nil or project.archived_at != nil
  end

  defp decide_running(row, now) do
    cond do
      now - row.last_activity > Previews.idle_ms() -> :stop
      row.lease_until > now and not Server.busy?(row.track_id) -> :ensure
      true -> :leave
    end
  end

  @doc false
  @spec reconcile({Row.t(), Track.t() | nil, Project.t() | nil}) :: :ok
  def reconcile({%Row{track_id: track_id} = row, track, project}) do
    result =
      case decide(row, track, project, Clock.now_ms()) do
        :cleanup -> Previews.stop_service(track_id, true)
        :stop -> Previews.stop_service(track_id, false, row.generation)
        :ensure -> Server.run(track_id, {:ensure_running, row.generation, false})
        :leave -> :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("ravix: preview reconciliation #{track_id} #{Server.message_of(reason)}")
    end

    :ok
  rescue
    error -> Logger.error("ravix: preview reconciliation #{track_id} #{Exception.message(error)}")
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @interval_ms)
    send(self(), :tick)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    tick()
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
