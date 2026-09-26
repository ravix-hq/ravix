defmodule RavixWeb.WorkspaceRailTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.{Fountain, Tracks}
  alias Ravix.Fountain.FakeTransport

  setup :verify_on_exit!

  test "Fountain reads overlap and the rail takes the slowest read rather than their sum", %{
    conn: conn
  } do
    user = insert_user()
    test_pid = self()
    delays = [800, 1_000, 1_200]

    rows =
      for delay <- delays do
        project = insert_project(user: user)
        track = insert_track(project: project, conversation_id: "conversation-#{project.id}")
        {project, track, delay}
      end

    client =
      FakeTransport.client(
        Enum.map(rows, fn {project, track, delay} ->
          {request(project),
           fn _ ->
             send(test_pid, {:reading, project.id})
             # Deliberately model provider latency; readiness is proved by
             # receiving all three starts before the first response can land.
             receive do
             after
               delay -> response(track)
             end
           end}
        end)
      )

    stub(Fountain, :client, fn -> client end)
    started = System.monotonic_time(:millisecond)
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    for {project, _, _} <- rows, do: assert_receive({:reading, id} when id == project.id, 500)
    html = render_async(view, 4_000)
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < Enum.sum(delays) - 400
    IO.puts("Concurrent rail: #{elapsed}ms for provider delays #{inspect(delays)}ms")
    for {project, _, _} <- rows, do: assert(html =~ project.name)

    for {project, track, _} <- rows do
      render_patch(view, "/p/#{project.id}")
      assert has_element?(view, ".track-tab", track.title)
    end

    assert length(FakeTransport.calls(client)) == 3
  end

  test "a timed-out project stays empty while another project's tracks render", %{conn: conn} do
    user = insert_user()
    slow = insert_project(user: user)
    fast = insert_project(user: user)
    slow_track = insert_track(project: slow, title: "Timed out", conversation_id: "slow")
    fast_track = insert_track(project: fast, title: "Available", conversation_id: "fast")
    test_pid = self()

    client =
      FakeTransport.client([
        {request(slow),
         fn _ ->
           send(test_pid, {:blocked_provider, self()})
           receive do: (:release -> response(slow_track))
         end},
        {request(fast), response(fast_track)}
      ])

    stub(Fountain, :client, fn -> client end)
    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    assert_receive {:blocked_provider, provider}, 1_000
    monitor = Process.monitor(provider)
    on_exit(fn -> send(provider, :release) end)
    render_async(view, 7_000)
    assert has_element?(view, ".workspace-project-name[href='/p/#{slow.id}']")
    render_patch(view, "/p/#{slow.id}")
    refute has_element?(view, ".track-tab", slow_track.title)
    render_patch(view, "/p/#{fast.id}")
    assert has_element?(view, ".track-tab", fast_track.title)

    # The memo owns its provider task and may have other waiters. Finish it
    # explicitly even though this rail's supervised waiter has timed out.
    send(provider, :release)
    assert_receive {:DOWN, ^monitor, :process, ^provider, _}, 1_000
  end

  test "a failed or crashed project cannot discard successful rail groups", %{conn: conn} do
    user = insert_user()
    projects = for _ <- 1..3, do: insert_project(user: user)
    [failed, crashed, good] = projects
    track = insert_track(project: good, title: "Survived")

    stub(Tracks, :list, fn _, id ->
      cond do
        id == failed.id -> {:error, :not_found}
        id == crashed.id -> exit(:rail_test_crash)
        true -> {:ok, [Tracks.present(track)]}
      end
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/home")
    render_async(view)

    for project <- projects do
      assert has_element?(view, ".workspace-project-name[href='/p/#{project.id}']")
      render_patch(view, "/p/#{project.id}")
      assert has_element?(view, ".track-tab", track.title) == (project.id == good.id)
    end
  end

  test "at most eight project reads run at once", %{conn: conn} do
    user = insert_user()
    projects = for _ <- 1..10, do: insert_project(user: user)
    test_pid = self()

    stub(Tracks, :list, fn _, id ->
      send(test_pid, {:worker, self(), id})
      receive do: (:release -> {:ok, []})
    end)

    {:ok, view, _} = live(log_in_user(conn, user), "/home")

    workers =
      for _ <- 1..8 do
        assert_receive {:worker, pid, _}, 1_000
        pid
      end

    refute_receive {:worker, _, _}, 100
    Enum.each(workers, &send(&1, :release))

    for _ <- 1..2 do
      assert_receive {:worker, pid, _}, 1_000
      send(pid, :release)
    end

    render_async(view)

    for project <- projects,
        do: assert(has_element?(view, ".workspace-project-name[href='/p/#{project.id}']"))

    refute has_element?(view, "#rail-loading")
  end

  defp request(project),
    do: %{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}}

  defp response(track),
    do: {200, [], %{data: [%{id: track.conversation_id, status: "idle", sandbox_id: "sandbox"}]}}
end
