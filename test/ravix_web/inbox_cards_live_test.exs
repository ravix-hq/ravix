defmodule RavixWeb.InboxCardsLiveTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.{Fountain, Hub, Repo}
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Hub.Event
  alias Ravix.People.AccessNotice
  alias Ravix.Tracks.{Reply, Thread}
  alias Ravix.Tracks.Transcript.Block
  alias Ravix.TranscriptFixture, as: TF
  alias Ravix.Workspaces.Store, as: Workspaces

  setup :verify_on_exit!

  # Fountain lists each track's conversation idle, a minute after anybody
  # last looked: every card is an unread reply.
  defp listing(project, tracks, extra \\ []) do
    active = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60))

    data =
      for track <- tracks,
          do: %{
            id: track.conversation_id,
            status: "idle",
            sandbox_id: "s",
            last_active_at: active
          }

    client =
      FakeTransport.client(
        [
          {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
           {200, [], %{data: data}}}
        ] ++ extra,
        verify: false
      )

    stub(Fountain, :client, fn -> client end)
    client
  end

  defp track(project, attrs),
    do:
      insert_track(
        [project: project, conversation_id: Ecto.UUID.generate(), opened_at: DateTime.utc_now()] ++
          attrs
      )

  defp excerpt(body),
    do: Reply.excerpt([%Block.Text{body: body, started_at: nil, ended_at: nil}])

  defp inbox(conn, user, params \\ %{}) do
    conn = conn |> log_in_user(user) |> put_connect_params(params)
    {:ok, view, _} = live(conn, "/inbox")
    render_async(view, 5_000)
    view
  end

  test "a card says what the agent replied, escaped and bounded, how long ago, and names the track by its title alone",
       %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    named = track(project, title: "fix-login", branch: "fix-login")
    branched = track(project, title: "Tidy the docs", branch: "ada/tidy-docs-1")
    keep_reply(named, excerpt("<script>alert(1)</script> **Fixed** it.\nSecond line\nThird line"))
    keep_reply(branched, excerpt(String.duplicate("A long reply. ", 60)))
    listing(project, [named, branched])

    view = inbox(conn, user)
    html = render(view)

    assert has_element?(
             view,
             "#inbox-excerpt-#{named.id}",
             "<script>alert(1)</script> Fixed it. Second line"
           )

    refute has_element?(view, "#inbox-excerpt-#{named.id}", "Third line")
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute html =~ "<script>alert(1)"

    long = view |> element("#inbox-excerpt-#{branched.id}") |> render() |> text()
    assert String.length(long) <= 200
    assert String.ends_with?(long, "…")
    refute html =~ "The agent finished. Open the conversation to read its reply."

    # A card names its track by `Track.label/1` and prints no branch slug
    # beside it, titled or not (RAV-83).
    card = &"a.inbox-item[href^='/p/#{project.id}/t/#{&1.id}?']"
    assert has_element?(view, "#{card.(named)} strong", "fix-login")
    refute has_element?(view, "#{card.(named)} code")
    assert has_element?(view, "#{card.(branched)} strong", "Tidy the docs")
    refute has_element?(view, "#{card.(branched)} code")
    refute html =~ "ada/tidy-docs-1"

    # The time is relative and machine-readable, and nothing says "UTC".
    assert has_element?(
             view,
             "#{card.(named)} time#inbox-age-#{named.id}[phx-hook=RelativeTime][data-style=ago][datetime]",
             "1m ago"
           )

    refute html =~ "UTC"
  end

  test "access notices carry a local time for the zone the browser reported", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    listing(project, [])
    at = ~U[2026-09-28 20:27:00.000000Z]
    {:ok, workspace} = Workspaces.create_team_workspace(user.id, "Team")

    %AccessNotice{}
    |> AccessNotice.changeset(%{
      track_id: track(project, title: "Moved").id,
      user_id: user.id,
      workspace_id: workspace.id,
      revoked_logins: ["someone"],
      created_at: at
    })
    |> Repo.insert!()

    view = inbox(conn, user, %{"timezone" => "America/New_York"})

    assert has_element?(
             view,
             ~s|time[phx-hook=LocalTime][datetime="2026-09-28T20:27:00.000000Z"]|,
             "4:27 PM"
           )

    refute render(view) =~ "UTC"
  end

  test "a reply nobody kept yet is fetched once, and the card fills in", %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    fresh = track(project, title: "Fresh work")

    page =
      {200, [],
       %{
         data:
           Enum.reverse([
             Map.put(TF.stage(1, "started"), "ts", "2026-09-28T16:00:00Z"),
             Map.put(TF.output(2, TF.text("Shipped the fix.")), "ts", "2026-09-28T16:26:00Z"),
             Map.put(TF.stage(3, "completed"), "ts", "2026-09-28T16:27:00Z")
           ]),
         meta: %{has_more: false},
         page: %{order: "desc", oldest_cursor: 1, newest_cursor: 3}
       }}

    events = %{method: "GET", path: "/api/conversations/#{fresh.conversation_id}/events"}
    client = listing(project, [fresh], [{events, page}])
    Hub.subscribe(project.id)

    view = inbox(conn, user)
    assert_receive {:hub, %{name: :reply}}, 5_000
    render_async(view, 5_000)
    assert has_element?(view, "#inbox-excerpt-#{fresh.id}", "Shipped the fix.")
    assert Repo.get!(Thread, fresh.id).reply_excerpt == "Shipped the fix."

    # Kept: the next redraw of the Inbox asks Fountain nothing more.
    send(view.pid, {:hub, Event.new(:machine, project.id)})
    render_async(view, 5_000)
    fetched = Enum.filter(FakeTransport.calls(client), &String.ends_with?(&1.path, "/events"))
    assert length(fetched) == 1
  end

  test "an excerpt kept while a live read is in flight shows once that read lands", %{
    conn: conn
  } do
    user = insert_user()
    project = insert_project(user: user)
    busy = track(project, title: "Busy work")
    keep_reply(busy, "Before")
    test = self()

    # The turn's live read waits until the test lets it answer, so the
    # `:reply` below arrives while it is in flight.
    held = fn _call ->
      send(test, {:listing, self()})

      receive do
        :answer -> :ok
      after
        5_000 -> :ok
      end

      {200, [],
       %{
         data: [
           %{
             id: busy.conversation_id,
             status: "idle",
             sandbox_id: "s",
             last_active_at: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60))
           }
         ]
       }}
    end

    listing = %{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}}
    listing(project, [busy], [{listing, held}])

    view = inbox(conn, user)
    assert has_element?(view, "#inbox-excerpt-#{busy.id}", "Before")

    send(view.pid, {:hub, Event.new(:turn, project.id, track_id: busy.id)})
    assert_receive {:listing, reader}, 5_000
    keep_reply(busy, "After")
    send(view.pid, {:hub, Event.new(:reply, project.id)})
    # Handled, and deferred: the live read is still the one in flight.
    render(view)
    send(reader, :answer)
    render_async(view, 5_000)
    render_async(view, 5_000)
    assert has_element?(view, "#inbox-excerpt-#{busy.id}", "After")
  end

  test "an excerpt never shows on a card the viewer could not open", %{conn: conn} do
    owner = insert_user()
    member = insert_user()
    stranger = insert_user()
    project = insert_project(user: owner)
    insert_project_member(project, member)

    private =
      track(project,
        title: "Owner's private work",
        visibility: :private,
        sandbox_layout: :dedicated,
        created_by: owner.id
      )

    shared = track(project, title: "Shared work")
    keep_reply(private, "Private reply text")
    keep_reply(shared, "Shared reply text")
    listing(project, [private, shared])

    assert has_element?(inbox(conn, owner), "#inbox-excerpt-#{private.id}", "Private reply text")

    member_view = inbox(build_conn(), member)
    assert has_element?(member_view, "#inbox-excerpt-#{shared.id}", "Shared reply text")
    refute render(member_view) =~ "Private reply text"

    stranger_view = inbox(build_conn(), stranger)
    refute render(stranger_view) =~ "reply text"
  end

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()
end
