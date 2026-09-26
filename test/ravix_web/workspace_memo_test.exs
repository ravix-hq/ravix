defmodule RavixWeb.WorkspaceMemoTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.{Fountain, MachineCache, Tracks}
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Hub.Event

  setup :verify_on_exit!

  test "two page loads within the TTL read Fountain once per project", %{conn: conn} do
    user = insert_user()

    rows =
      for _ <- 1..2 do
        project = insert_project(user: user)

        track =
          insert_track(
            project: project,
            conversation_id: "conversation-#{project.id}",
            opened_at: DateTime.utc_now()
          )

        {project, track}
      end

    client = FakeTransport.client(Enum.map(rows, fn {p, t} -> {request(p), conversations(t)} end))
    stub(Fountain, :client, fn -> client end)
    started = System.monotonic_time(:millisecond)

    for _ <- 1..2 do
      {:ok, view, _} = live(log_in_user(conn, user), "/home")
      render_async(view)

      for {project, track} <- rows do
        render_patch(view, "/p/#{project.id}")
        assert has_element?(view, ".track-tab", track.title)
      end
    end

    assert System.monotonic_time(:millisecond) - started < MachineCache.ttl_ms()
    assert length(FakeTransport.calls(client)) == 2
  end

  test "explicit refresh and turn events read live status despite a warm memo", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)

    track =
      insert_track(
        project: project,
        conversation_id: "conversation-#{project.id}",
        opened_at: DateTime.utc_now()
      )

    client =
      FakeTransport.client([
        {request(project), conversations(track)},
        {request(project), conversations(track, "running")},
        {request(project), conversations(track)}
      ])

    stub(Fountain, :client, fn -> client end)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    render_async(view)
    refute has_element?(view, ".track-tab [aria-label='Working']")
    assert length(FakeTransport.calls(client)) == 1

    render_click(view, "refresh")
    render_async(view)
    assert has_element?(view, ".track-tab [aria-label='Working']")
    assert length(FakeTransport.calls(client)) == 2

    send(view.pid, {:hub, Event.new(:turn, project.id, track_id: track.id)})
    render_async(view)
    refute has_element?(view, ".track-tab [aria-label='Working']")
    assert has_element?(view, ".track-tab [aria-label='Unread reply']")
    assert length(FakeTransport.calls(client)) == 3
  end

  test "read PubSub clears both tabs immediately and cached reloads do not restore unread", %{
    conn: conn
  } do
    user = insert_user()
    project = insert_project(user: user)

    track =
      insert_track(
        project: project,
        conversation_id: "conversation-#{project.id}",
        opened_at: DateTime.utc_now()
      )

    client = FakeTransport.client([{request(project), conversations(track)}])
    stub(Fountain, :client, fn -> client end)

    tabs =
      for _ <- 1..2 do
        {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
        render_async(view)
        assert has_element?(view, ".track-tab [aria-label='Unread reply']")
        view
      end

    assert :ok = Tracks.mark_read(user, track.id)

    for view <- tabs do
      refute render_async(view) =~ "Unread reply"
      # A non-turn rail reload still reads the user's markers from the DB.
      send(view.pid, {:hub, Event.new(:settings, project.id)})
      refute render_async(view) =~ "Unread reply"
    end

    assert {:ok, threads} = Tracks.threads(user, track.id)
    refute Enum.any?(threads, & &1.unread)
    assert length(FakeTransport.calls(client)) == 1
  end

  defp request(project),
    do: %{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}}

  defp conversations(track, status \\ "idle") do
    {200, [],
     %{
       data: [
         %{
           id: track.conversation_id,
           status: status,
           sandbox_id: "sandbox",
           last_active_at: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60, :second))
         }
       ]
     }}
  end
end
