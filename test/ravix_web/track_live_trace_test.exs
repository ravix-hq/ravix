defmodule RavixWeb.TrackLiveTraceTest do
  @moduledoc """
  The whole chain, once, through a real page (ADR 0004).

  `Ravix.TraceSpanTest` proves `Ravix.Trace`'s pieces in isolation. This proves
  the thing those pieces exist for and that no unit test can see: a click on the
  track page produces **one** trace, with the read the click started inside it,
  across a process boundary.

  It is worth a file of its own because every link in that chain is somebody
  else's code or a boot-time side effect --- `OpentelemetryPhoenix`'s LiveView
  handler being attached by `Ravix.Trace.Setup`, LiveView's own `handle_event`
  telemetry, and `RavixWeb.Live.Async.traced_async/3` --- so any one of them can
  stop working without a unit test failing. What that failure looks like in
  Honeycomb is a waterfall that no longer explains anything: the click and the
  read filed as two unrelated traces, and no way to see which of a page's reads
  was the slow one.

  The context call is stubbed, and the stub opens a span. That is the point
  rather than a shortcut: what is under test is whether `traced_async/3` carries
  the context into the task, so the stub stands in for "a context function with
  a span in it", which every instrumented one is. It returns the real
  `Files.Listing` struct, because a stub that returns a map hides the template
  bugs only a real shape catches.
  """
  use RavixWeb.ConnCase, async: false
  use Ravix.TraceCase, async: false

  import Mimic
  import Phoenix.LiveViewTest

  alias Ravix.Trace
  alias Ravix.Tracks
  alias Ravix.Tracks.Files
  alias Ravix.Tracks.Track
  alias Ravix.Tracks.Transcript

  setup %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)

    track =
      insert_track(
        project: project,
        conversation_id: "live-conversation",
        created_by_login: user.login
      )

    stub(Tracks, :get, fn _, id, _opts ->
      {:ok,
       %{
         track: Tracks.present(Ravix.Repo.get!(Track, id), role: :owner),
         header: %Tracks.Header{
           copy_of: nil,
           branched_from: nil,
           created: %{dir: "t", files: nil},
           has_setup_script: false
         },
         threads: [],
         starters: [],
         models: []
       }}
    end)

    stub(Tracks, :events, fn _, _, _thread_opts -> {:ok, Transcript.empty("claude")} end)
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _, _thread_opts -> :ok end)

    # The one read this test follows. Spanned inside the stub, standing in for
    # any instrumented context call; the shape is the real one.
    stub(Tracks, :files, fn _user, track_id, path ->
      Trace.span("tracks.files", %{"ravix.track_id" => track_id}, fn ->
        {:ok, %Files.Listing{path: path || "/w", truncated: false, entries: []}}
      end)
    end)

    {:ok, parent, _html} = live(log_in_user(conn, user), "/p/#{project.id}/t/#{track.id}")
    view = find_live_child(parent, "track-host")

    %{view: view, track: track}
  end

  test "a click and the read it starts are one trace", %{view: view, track: track} do
    # The mount reads too, and `tracks.files` is one of the reads it does. This
    # test is about the *event*, so its assertions have to start from a clean
    # mailbox or they would match the mount's span and prove nothing.
    drain_spans()

    render_click(view, "panel", %{"name" => "files"})

    # In the order they end, which is not the order they nest: `start_async/3`
    # returns immediately, so the event span closes while the read it started is
    # still running. `await_span/1` discards what it passes over, so asking for
    # the read first would throw the event away.
    event = await_span("RavixWeb.TrackLive.handle_event#panel")
    read = await_span("tracks.files")

    assert field(read, :parent_span_id) == field(event, :span_id),
           """
           The read was not a child of the LiveView event, so `traced_async/3` is no longer
           carrying the trace context into the task. In Honeycomb this looks like a page
           whose reads are orphan single-span traces, with no way to see which was slow.
           """

    assert field(read, :trace_id) == field(event, :trace_id)
    assert attributes(read)["ravix.track_id"] == track.id
  end

  defp drain_spans do
    receive do
      {:span, _} -> drain_spans()
    after
      0 -> :ok
    end
  end
end
