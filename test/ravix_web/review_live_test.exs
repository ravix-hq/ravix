defmodule RavixWeb.ReviewLiveTest do
  use RavixWeb.ConnCase, async: true
  use Mimic
  import Phoenix.LiveViewTest
  alias Ravix.{Accounts, People, Repo, Reviews, Tracks}
  alias Ravix.Reviews.Anchor
  alias Ravix.Tracks.{Diff, Files, Header, Track, Transcript}

  setup %{conn: conn} do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project, conversation_id: "reviews-live")
    patch = File.read!("test/fixtures/diff/files.patch")

    diff = %Diff{
      path: "/work",
      repo_root: "/work",
      diff: patch,
      truncated: false,
      files: Diff.parse(patch),
      changes: Diff.summarize(patch),
      untracked: :listed
    }

    stub(Tracks, :get, fn _, id, _ ->
      row = Repo.get!(Track, id)

      {:ok,
       %{
         track: Tracks.present(row, role: :owner),
         header: %Header{
           copy_of: nil,
           branched_from: nil,
           created: %{dir: "t", files: nil},
           has_setup_script: false
         },
         threads: [%{id: id, title: row.title, runtime: "claude", unread: false}],
         starters: [],
         models: []
       }}
    end)

    stub(Tracks, :events, fn _, _, _ -> {:ok, Transcript.empty("claude")} end)
    stub(Tracks, :follow, fn _, _, _ -> {:ok, self()} end)
    stub(Tracks, :beat, fn _, _, _ -> :ok end)
    stub(Tracks, :mark_read, fn _, _, _ -> :ok end)

    stub(Tracks, :files, fn _, _, _ ->
      {:ok, %Files.Listing{path: "/work", truncated: false, entries: []}}
    end)

    stub(Tracks, :diff, fn _, _ -> {:ok, diff} end)

    stub(Tracks, :checks, fn _, _ ->
      {:ok, %Ravix.GitHub.ChecksReport{ref: "main", pull: nil, runs: [], pushed: false, sha: nil}}
    end)

    stub(Tracks, :git_status, fn _, _ -> {:error, :machine_asleep} end)
    conn = log_in_user(conn, user)
    {:ok, parent, _} = live(conn, "/p/#{project.id}/t/#{track.id}")
    view = find_live_child(parent, "track-host")
    render_async(view, 5000)
    render_async(view, 5000)
    render_click(view, "panel", %{name: "changes"})
    render_async(view, 5000)

    %{
      conn: conn,
      user: user,
      track: track,
      project: project,
      diff: diff,
      parent: parent,
      view: view
    }
  end

  test "line selection creates a persisted discussion, replies/resolves and navigates from Checks",
       c do
    render_click(c.view, "select-diff", %{path: "space name.txt"})

    c.view
    |> element("button[phx-click=review-anchor][phx-value-side=new][phx-value-line='2']")
    |> render_click()

    c.view |> form("#review-post-form", %{body: "Inspect this change"}) |> render_submit()
    render_async(c.view, 5000)
    assert {:ok, [discussion]} = Reviews.list(c.user, c.track.id)
    assert {discussion.path, discussion.side, discussion.line} == {"space name.txt", "new", 2}
    assert discussion.excerpt == "<script>alert(1)</script>"
    refute has_element?(c.view, "#diff-review script")
    c.view |> form("#review-reply-#{discussion.id}", %{body: "Checked"}) |> render_submit()
    assert {:ok, [updated]} = Reviews.list(c.user, c.track.id)
    assert Enum.map(updated.messages, & &1.body) == ["Inspect this change", "Checked"]

    c.view
    |> element("button[phx-click=review-resolve][phx-value-id='#{discussion.id}']")
    |> render_click()

    assert {:ok, [%{resolved: true}]} = Reviews.list(c.user, c.track.id)
    render_click(c.view, "panel", %{name: "checks"})
    render_async(c.view, 5000)

    c.view
    |> element("a[phx-click=review-jump][phx-value-id='#{discussion.id}']")
    |> render_click()

    render_async(c.view, 5000)
    assert has_element?(c.view, "#review-discussion-#{discussion.id}[data-selected=true]")

    assert has_element?(
             c.view,
             "button[phx-click=review-anchor][phx-value-path='space name.txt']"
           )

    assert {:ok, []} = Ravix.Comments.list(c.user, c.track.id, nil)
  end

  test "stale submission retains its draft, old discussions survive an empty diff", c do
    anchor = anchor(c)
    {:ok, discussion} = Reviews.open(c.user, c.track.id, anchor, "Original")
    render_click(c.view, "review-anchor", anchor)
    empty = %{c.diff | diff: "", files: [], changes: []}
    stub(Tracks, :diff, fn _, _ -> {:ok, empty} end)
    c.view |> form("#review-post-form", %{body: "Keep my draft"}) |> render_submit()
    render_async(c.view, 5000)
    assert {:ok, [original]} = Reviews.list(c.user, c.track.id)
    assert original.id == discussion.id
    assert has_element?(c.view, "#review-post-form textarea", "Keep my draft")
    assert has_element?(c.view, "#diff-review [role=alert]")
    render_click(c.view, "refresh-panel", %{})
    render_async(c.view, 5000)
    assert has_element?(c.view, "#review-discussion-#{discussion.id}[data-outdated=true]")
    c.view |> form("#review-reply-#{discussion.id}", %{body: "Retained"}) |> render_submit()
    assert {:ok, [%{messages: messages}]} = Reviews.list(c.user, c.track.id)
    assert length(messages) == 2
  end

  test "forged discussion IDs cannot mutate another track", c do
    other = insert_track(project: c.project)
    {:ok, discussion} = Reviews.open(c.user, other.id, anchor(c), "Other track")
    render_hook(c.view, "review-reply", %{discussion_id: discussion.id, body: "Forged"})
    render_hook(c.view, "review-resolve", %{id: discussion.id, resolved: "true"})
    assert {:ok, [%{resolved: false, messages: messages}]} = Reviews.list(c.user, other.id)
    assert length(messages) == 1
    assert has_element?(c.view, "#diff-review [role=alert]")
    render_hook(c.view, "review-jump", %{id: discussion.id})
    render_async(c.view, 5000)
    refute has_element?(c.view, "#review-discussion-#{discussion.id}")
  end

  test "a revoked session cannot post even while the parent's cached guard still holds", c do
    render_click(c.view, "review-anchor", anchor(c))
    token = get_session(c.conn, :session_token)
    session = Repo.get_by!(Accounts.Session, token_hash: Ravix.Crypto.sha256(token))
    Repo.delete!(session)

    assert {:error, {:redirect, %{to: "/login"}}} =
             render_hook(c.view, "review-post", %{body: "Revoked"})

    assert {:ok, []} = Reviews.list(c.user, c.track.id)
  end

  test "a removed member cannot reply or receive review updates", c do
    member = insert_user()
    insert_track_member(c.track, member)
    {:ok, _discussion} = Reviews.open(c.user, c.track.id, anchor(c), "Restricted")
    conn = log_in_user(build_conn(), member)
    {:ok, parent, _} = live(conn, "/p/#{c.project.id}/t/#{c.track.id}")
    view = find_live_child(parent, "track-host")
    render_async(view, 5000)
    render_async(view, 5000)
    assert {:ok, _} = People.remove(c.user, c.track.id, member.login)

    assert_redirect(parent, "/", 2000)

    assert {:ok, [%{messages: messages}]} = Reviews.list(c.user, c.track.id)
    assert length(messages) == 1
  end

  test "async create result is rejected after session revocation while provider is pending", c do
    render_click(c.view, "review-anchor", anchor(c))
    test_pid = self()

    expect(Tracks, :diff, fn _, _ ->
      send(test_pid, {:pending_review, self()})
      receive do: (:finish -> {:ok, c.diff})
    end)

    c.view |> form("#review-post-form", %{body: "Delayed"}) |> render_submit()
    assert_receive {:pending_review, task}, 2000
    token = get_session(c.conn, :session_token)
    Repo.delete!(Repo.get_by!(Accounts.Session, token_hash: Ravix.Crypto.sha256(token)))
    send(task, :finish)
    assert_redirect(c.parent, "/login", 2000)
    assert {:ok, []} = Reviews.list(c.user, c.track.id)
  end

  test "pending submissions coalesce and provider failures keep the editable draft", c do
    render_click(c.view, "review-anchor", anchor(c))
    test_pid = self()

    expect(Tracks, :diff, fn _, _ ->
      send(test_pid, {:pending_failure, self()})
      receive do: (:finish -> {:error, :machine_asleep})
    end)

    render_hook(c.view, "review-post", %{body: "Retain this"})
    assert_receive {:pending_failure, task}, 2000
    render_hook(c.view, "review-post", %{body: "Duplicate"})
    send(task, :finish)
    render_async(c.view, 5000)
    assert {:ok, []} = Reviews.list(c.user, c.track.id)
    assert has_element?(c.view, "#review-post-form textarea", "Retain this")
    refute has_element?(c.view, "#review-post-form textarea[disabled]")
    assert has_element?(c.view, "#diff-review [role=alert]")
    render_hook(c.view, "review-cancel", %{})
    refute has_element?(c.view, "#review-post-form")
    render_hook(c.view, "review-post", %{body: "No anchor"})
    render_hook(c.view, "review-resolve", %{id: "bad", resolved: "bad"})
    render_hook(c.view, "review-unrecognized", %{})
    assert {:ok, []} = Reviews.list(c.user, c.track.id)
  end

  test "unavailable and forged coordinates cannot open a composer", c do
    render_hook(c.view, "review-anchor", %{anchor(c) | "line" => "999"})
    refute has_element?(c.view, "#review-post-form")
    assert has_element?(c.view, "#diff-review [role=alert]")

    :sys.replace_state(c.view.pid, fn state ->
      update_in(state.socket.assigns.panel, &%{&1 | data: nil, cache: %{}})
    end)

    render_hook(c.view, "review-anchor", anchor(c))
    refute has_element?(c.view, "#review-post-form")
    assert has_element?(c.view, "#diff-review [role=alert]")
  end

  test "review messages clear discussions after silent membership removal, events refuse writes",
       c do
    member = insert_user()
    membership = insert_track_member(c.track, member)
    {:ok, discussion} = Reviews.open(c.user, c.track.id, anchor(c), "Restricted discussion")

    {:ok, parent, _} =
      live(log_in_user(build_conn(), member), "/p/#{c.project.id}/t/#{c.track.id}")

    view = find_live_child(parent, "track-host")
    render_async(view, 5000)
    render_async(view, 5000)
    render_click(view, "panel", %{name: "changes"})
    render_async(view, 5000)
    assert has_element?(view, "#review-discussion-#{discussion.id}")
    Repo.delete!(membership)

    send(
      view.pid,
      {:hub, %Ravix.Hub.Event{name: :review, project_id: c.project.id, track_id: c.track.id}}
    )

    refute has_element?(view, "#review-discussion-#{discussion.id}")

    assert {:error, {:redirect, _}} =
             render_hook(view, "review-reply", %{discussion_id: discussion.id, body: "Removed"})

    assert {:ok, [%{messages: messages}]} = Reviews.list(c.user, c.track.id)
    assert length(messages) == 1
  end

  test "malformed draft payloads cannot replace entered text or write a review", c do
    render_click(c.view, "review-anchor", anchor(c))
    render_hook(c.view, "review-draft", %{body: "Typed draft"})
    render_hook(c.view, "review-draft", %{body: %{bad: "payload"}})
    render_hook(c.view, "review-post", %{body: ["bad payload"]})
    assert has_element?(c.view, "#review-post-form textarea", "Typed draft")
    assert {:ok, []} = Reviews.list(c.user, c.track.id)
  end

  defp anchor(c),
    do: %{
      "revision" => Anchor.revision(c.diff),
      "path" => "added.txt",
      "side" => "new",
      "line" => "1"
    }
end
