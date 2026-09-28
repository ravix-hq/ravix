defmodule RavixWeb.ThreadCommentsLiveTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.{Comments, Repo, Tracks}
  alias Ravix.Hub.Event
  alias Ravix.Tracks.{Track, Transcript}

  setup :verify_on_exit!

  setup %{conn: conn} do
    owner = insert_user()
    member = insert_user()
    outsider = insert_user()
    project = insert_project(user: owner)
    insert_project_member(project, member)

    track =
      insert_track(
        project: project,
        conversation_id: "conv",
        created_by_login: owner.login,
        setup_state: "ready",
        opened_at: DateTime.utc_now()
      )

    # Somebody on a private sibling track, and on another project entirely.
    creator = insert_user()
    insert_project_member(project, creator)

    insert_track(
      project: project,
      visibility: :private,
      created_by: creator.id,
      created_by_login: creator.login
    )

    insert_project(user: outsider)

    stub(Tracks, :get, fn user, id, _opts ->
      row = Repo.get!(Track, id)

      {:ok, threads} = Tracks.threads(user, id)

      {:ok,
       %{
         track: Tracks.present(row, role: :owner),
         header: %Tracks.Header{
           copy_of: nil,
           branched_from: nil,
           created: %{dir: row.slug, files: nil},
           has_setup_script: false
         },
         threads: threads,
         starters: [],
         models: []
       }}
    end)

    stub(Tracks, :events, fn _, _, _ -> {:ok, transcript([{"t1", "first"}, {"t2", "second"}])} end)

    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :files, fn _, _, _ -> {:error, :not_found} end)

    %{
      conn: conn,
      owner: owner,
      member: member,
      creator: creator,
      outsider: outsider,
      project: project,
      track: track
    }
  end

  defp open(ctx, user) do
    {:ok, parent, _} =
      live(log_in_user(build_conn(), user), "/p/#{ctx.project.id}/t/#{ctx.track.id}")

    view = find_live_child(parent, "track-host")
    render_async(view, 5_000)
    render_async(view, 5_000)
    {parent, view}
  end

  defp comment_mode(view), do: view |> element("#composer-mode-comment") |> render_click()

  defp submit(view, text), do: view |> form("#composer-form", %{text: text}) |> render_submit()

  defp stored(track),
    do: Repo.all(Ravix.Comments.Comment) |> Enum.filter(&(&1.track_id == track.id))

  test "the toggle changes the box's labels, and a comment never becomes a prompt", ctx do
    reject(&Tracks.prompt/3)
    {_parent, view} = open(ctx, ctx.owner)

    assert has_element?(view, "#composer-mode-ask[aria-pressed=true]")
    assert has_element?(view, "textarea[aria-label=Message]")
    assert has_element?(view, "button.composer-send[aria-label=Send]")
    assert has_element?(view, "button[aria-label='Choose images']")
    refute has_element?(view, "#mention-options")

    comment_mode(view)
    assert has_element?(view, "#composer-mode-comment[aria-pressed=true]")
    assert has_element?(view, ".composer-box.commenting")
    assert has_element?(view, "#composer-mode-hint", "Comment — not sent to the agent")
    assert has_element?(view, "textarea[aria-label=Comment][aria-describedby=composer-mode-hint]")
    assert has_element?(view, "button.composer-send[aria-label='Post comment']")
    refute has_element?(view, "button[aria-label='Choose images']")

    view |> element("#composer-mode-ask") |> render_click()
    assert has_element?(view, "textarea[aria-label=Message]")
    comment_mode(view)

    submit(view, "Heads up: **careful** <script>alert(1)</script>")
    assert [comment] = stored(ctx.track)
    assert comment.anchor_turn_id == "t2"
    assert comment.author_id == ctx.owner.id

    # Drawn inline after the turn it followed, escaped, and back to Ask.
    assert has_element?(view, "#turns-t2 #comment-#{comment.id}", "Heads up")
    assert has_element?(view, "#comment-#{comment.id} strong", "careful")
    refute render(view) =~ "<script>alert(1)"
    assert has_element?(view, "#composer-mode-ask[aria-pressed=true]")
    assert has_element?(view, "textarea[aria-label=Message]")

    # An empty comment is refused where it was typed.
    comment_mode(view)
    submit(view, "   ")
    assert has_element?(view, "#thread-error")
    assert has_element?(view, "#composer-mode-comment[aria-pressed=true]")
  end

  test "a draft thread has nothing to comment on: no toggle, and Comment mode is left", ctx do
    stub(Tracks, :thread_options, fn _, _ -> {:error, :not_found} end)
    {_parent, view} = open(ctx, ctx.owner)
    comment_mode(view)
    assert has_element?(view, ".composer-box.commenting")

    render_click(view, "draft-thread", %{})
    refute has_element?(view, "#composer-mode-comment")
    refute has_element?(view, ".composer-box.commenting")
    # A forged toggle while drafting changes nothing.
    render_click(view, "composer-mode", %{"mode" => "comment"})
    refute has_element?(view, ".composer-box.commenting")
    refute has_element?(view, "#mention-options")
  end

  test "the mention list offers only the people who can reach the track", ctx do
    {_parent, view} = open(ctx, ctx.member)
    comment_mode(view)

    assert has_element?(
             view,
             "#mention-options[role=listbox] [role=option][data-login='#{ctx.owner.login}']"
           )

    assert has_element?(view, "[role=option][data-login='#{ctx.creator.login}']")
    refute has_element?(view, "[role=option][data-login='#{ctx.member.login}']")
    refute has_element?(view, "[role=option][data-login='#{ctx.outsider.login}']")
  end

  test "comments sit at their anchor, and wait for Load earlier when theirs is older", ctx do
    history = %Transcript.History{chunks: [[%{"id" => 1}]], source: :fixture}

    stub(Tracks, :events, fn _, _, _ ->
      {:ok, %{transcript([{"new", "newest"}], from: 20) | history: history}}
    end)

    {:ok, on_new} =
      Comments.post(ctx.member, ctx.track.id, nil, "about newest", %{anchor_turn_id: "new"})

    {:ok, on_old} =
      Comments.post(ctx.member, ctx.track.id, nil, "about earlier", %{anchor_turn_id: "old"})

    {:ok, first} = Comments.post(ctx.member, ctx.track.id, nil, "before anything")

    {_parent, view} = open(ctx, ctx.owner)
    assert has_element?(view, "#turns-new #comment-#{on_new.id}", "about newest")
    refute has_element?(view, "#comment-#{on_old.id}")
    refute has_element?(view, "#comment-#{first.id}")

    stub(Tracks, :earlier_events, fn _, _, _, _ ->
      {:ok,
       %{transcript([{"old", "earlier"}]) | history: %{history | chunks: []}, oldest_event_id: 1}}
    end)

    render_click(view, "load-earlier", %{})
    render_async(view)
    refute has_element?(view, "#load-earlier")
    assert has_element?(view, "#turns-old #comment-#{on_old.id}", "about earlier")
    assert has_element?(view, "#turns-new #comment-#{on_new.id}")
    assert has_element?(view, "#transcript-leading-comments #comment-#{first.id}")
  end

  test "a second session sees posts, edits and deletes live; only the author may change them",
       ctx do
    {_parent, mine} = open(ctx, ctx.owner)
    {_parent, theirs} = open(ctx, ctx.member)

    comment_mode(mine)
    submit(mine, "Shipping at five")
    [comment] = stored(ctx.track)
    render(theirs)
    assert has_element?(theirs, "#comment-#{comment.id}", "Shipping at five")
    refute has_element?(theirs, "#comment-#{comment.id} button", "Edit")
    assert has_element?(mine, "#comment-#{comment.id} button", "Edit")

    # Somebody else's edit is refused even if they send the event.
    render_click(theirs, "delete-comment", %{"id" => comment.id})
    assert is_nil(Repo.reload(comment).deleted_at)

    mine |> element("#comment-#{comment.id} button", "Edit") |> render_click()
    assert has_element?(mine, "#comment-edit-#{comment.id} textarea", "Shipping at five")
    mine |> element("#comment-edit-#{comment.id} button", "Cancel") |> render_click()
    refute has_element?(mine, "#comment-edit-#{comment.id}")

    mine |> element("#comment-#{comment.id} button", "Edit") |> render_click()
    mine |> form("#comment-edit-#{comment.id}", %{body: "Shipping at six"}) |> render_submit()
    render(theirs)
    assert has_element?(theirs, "#comment-#{comment.id}", "Shipping at six")
    assert has_element?(theirs, "#comment-#{comment.id} .thread-comment-edited", "edited")

    mine |> element("#comment-#{comment.id} button", "Delete") |> render_click()
    render(theirs)
    assert has_element?(theirs, "#comment-#{comment.id}", "Comment deleted")
    refute render(theirs) =~ "Shipping at six"
  end

  test "a revoked member's page leaves on the next comment rather than reading it", ctx do
    {parent, theirs} = open(ctx, ctx.member)
    ref = Process.monitor(theirs.pid)
    Repo.delete_all(Ravix.Projects.ProjectMember)

    # The comment's own hub event is what they hear, and it reads through the
    # door, which now refuses: the rail drops the project and the page goes.
    {:ok, _comment} = Comments.post(ctx.owner, ctx.track.id, nil, "after they left")
    assert_receive {:DOWN, ^ref, :process, _, _reason}, 5_000
    refute render(parent) =~ "after they left"
    assert {:error, :not_found} = Comments.list(ctx.member, ctx.track.id, nil)
  end

  test "a comment marks the thread unread in other people's rails, not the author's", ctx do
    for user <- [ctx.owner, ctx.member], do: Tracks.mark_read(user, ctx.track.id)
    # They are on the project but not looking at the track.
    {:ok, rail, _} = live(log_in_user(build_conn(), ctx.member), "/p/#{ctx.project.id}")
    render_async(rail)
    {my_parent, mine} = open(ctx, ctx.owner)
    render_async(my_parent)
    refute has_element?(rail, ".track-tab [aria-label='New comment']")

    comment_mode(mine)
    submit(mine, "@#{ctx.member.login} can you look?")
    render_async(rail)
    render_async(my_parent)

    assert has_element?(rail, ".track-tab [role=img][aria-label='New comment']")
    refute has_element?(my_parent, ".track-tab [aria-label='New comment']")

    # The mention puts it in their Inbox, by name, and nobody else's.
    {:ok, inbox, _} = live(log_in_user(build_conn(), ctx.member), "/inbox")
    render_async(inbox)
    assert has_element?(inbox, ".inbox-item", "Mentioned")
    assert has_element?(inbox, ".inbox-item", "@#{ctx.owner.login} mentioned you in a comment.")
    {:ok, inbox, _} = live(log_in_user(build_conn(), ctx.owner), "/inbox")
    render_async(inbox)
    refute has_element?(inbox, ".inbox-item", "Mentioned")
  end

  # A page for `turns`, each an ACP agent message saying `text`.
  defp transcript(turns, opts \\ []) do
    {events, _} =
      Enum.flat_map_reduce(turns, Keyword.get(opts, :from, 1), fn {id, text}, next ->
        frame =
          Jason.encode!(%{
            jsonrpc: "2.0",
            method: "session/update",
            params: %{
              update: %{
                sessionUpdate: "agent_message_chunk",
                content: %{type: "text", text: text}
              }
            }
          })

        {[
           %{
             "id" => next,
             "turn_id" => id,
             "kind" => "stage",
             "stage" => "turn",
             "state" => "started",
             "blocks" => [%{"kind" => "prompt", "body" => id}]
           },
           %{
             "id" => next + 1,
             "turn_id" => id,
             "kind" => "output",
             "stream" => "acp",
             "data" => frame
           }
         ], next + 2}
      end)

    Transcript.page(events, "claude")
  end
end
