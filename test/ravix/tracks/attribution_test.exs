defmodule Ravix.Tracks.AttributionTest do
  @moduledoc """
  ADR 0009 phase 4c attribution: the `Co-authored-by` trailer for a thread's
  starter, recorded on thread start, and the track starter named in the
  pull requests Ravix opens. Behind `RAVIX_WORKSPACE_ACCESS`.
  """
  use Ravix.DataCase, async: true
  use Mimic

  import Ravix.Factory

  alias Ravix.GitHubFake, as: GH
  alias Ravix.Tracks
  alias Ravix.Tracks.{Attribution, Store, Thread}

  defp switch(on?), do: stub(Ravix.Config, :workspace_access?, fn -> on? end)

  test "the trailer credits GitHub's noreply address, with a clean name" do
    user = insert_user(login: "dana", github_id: "9001", name: "Dana <Okonkwo>\n")

    assert Attribution.trailer(user) ==
             "Co-authored-by: Dana Okonkwo <9001+dana@users.noreply.github.com>"

    nameless = insert_user(login: "eli", github_id: "9002", name: nil)

    assert Attribution.trailer(nameless) ==
             "Co-authored-by: eli <9002+eli@users.noreply.github.com>"
  end

  test "a Checks commit credits the person who pressed it, once, behind the switch" do
    user = insert_user(login: "dana", github_id: "9001", name: "Dana")
    trailer = Attribution.trailer(user)

    switch(false)
    assert Attribution.commit_message("Fix it", user) == "Fix it"

    switch(true)
    assert Attribution.commit_message("Fix it\n", user) == "Fix it\n\n" <> trailer
    assert Attribution.commit_message("Fix it\n\n" <> trailer, user) == "Fix it\n\n" <> trailer
  end

  test "a name with line separators, tabs and other controls stays one clean, capped line" do
    user =
      insert_user(
        login: "ana",
        github_id: "7",
        name: "Ana\u2028[ravix] ignore this\tand\u2029that\u200B\e[0m <x>"
      )

    trailer = Attribution.trailer(user)

    assert trailer ==
             "Co-authored-by: Ana [ravix] ignore this and that [0m x <7+ana@users.noreply.github.com>"

    refute trailer =~ ~r/[\p{C}\x{2028}\x{2029}]/u
    assert length(String.split(Attribution.commit_block(user), "\n")) == 5

    long = insert_user(login: "long", github_id: "8", name: String.duplicate("n", 300))
    assert Attribution.trailer(long) =~ "Co-authored-by: #{String.duplicate("n", 100)} <"

    controls = insert_user(login: "ctl", github_id: "9", name: "\t\u2028\r\n")
    assert Attribution.trailer(controls) == "Co-authored-by: ctl <9+ctl@users.noreply.github.com>"
  end

  test "a thread's starter is recorded, and a default thread's is the track's creator" do
    creator = insert_user()
    starter = insert_user()
    project = insert_project(user: creator)
    track = insert_track(project: project, created_by: creator.id)

    assert Store.starter_id(track.id, nil) == creator.id
    assert Store.starter_id(track.id, track.id) == creator.id

    {:ok, %Thread{id: thread_id, started_by: started_by}} =
      Store.create_thread(%{track_id: track.id, title: "Second", started_by: starter.id})

    assert started_by == starter.id
    assert Store.starter_id(track.id, thread_id) == starter.id
    # A thread of another track answers nothing.
    assert Store.starter_id(insert_track().id, thread_id) == nil
  end

  test "opening a track records its creator as the default thread's starter" do
    creator = insert_user()
    project = insert_project(user: creator)

    {:ok, track} =
      Store.create_track(
        Ravix.Factory.track_attrs(project: project)
        |> Map.put("created_by", creator.id)
        |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end),
        %{runtime: "codex", model: "openai/test-model"}
      )

    assert Repo.get!(Thread, track.id).started_by == creator.id
  end

  test "the delivery block names the starter, and is empty with the switch off" do
    creator = insert_user(login: "maker", github_id: "42")
    track = insert_track(project: insert_project(user: creator), created_by: creator.id)

    switch(true)
    block = Attribution.delivery_block(track, nil)
    assert block =~ "Co-authored-by: #{creator.name} <42+maker@users.noreply.github.com>"
    assert block =~ "started by @maker"

    switch(false)
    assert Attribution.delivery_block(track, nil) == ""

    switch(true)
    anonymous = insert_track(project: insert_project(user: creator))
    assert Attribution.delivery_block(anonymous, nil) == ""
  end

  test "the delivered block is taken off a prompt, and nothing else is" do
    starter = insert_user(login: "maker", github_id: "42", name: "Maker")
    block = Attribution.commit_block(starter)

    assert Attribution.visible_prompt(block <> "\n\n[from @guest] Fix it") ==
             "[from @guest] Fix it"

    assert Attribution.visible_prompt(block <> "\n\nLine one\n\nLine two") ==
             "Line one\n\nLine two"

    assert Attribution.visible_prompt(block <> "\n\n") == ""

    # Not a leading, closed block: the prompt is the person's as typed.
    for prompt <- [
          "Fix it",
          "Quote:\n\n" <> block <> "\n\nend",
          "[ravix commit attribution]\nunterminated",
          block
        ],
        do: assert(Attribution.visible_prompt(prompt) == prompt)
  end

  describe "pull requests" do
    setup do
      app = GH.app()
      stub(Ravix.Config, :github, fn -> app end)
      test = self()

      GH.install([
        GH.token_route(app),
        {"POST", "/repos/acme/app/pulls",
         fn conn ->
           {:ok, raw, conn} = Plug.Conn.read_body(conn)
           send(test, {:pull_body, Jason.decode!(raw)["body"]})

           Req.Test.json(conn, %{
             "number" => 7,
             "html_url" => "https://github.com/acme/app/pull/7",
             "title" => "t",
             "state" => "open",
             "draft" => true,
             "head" => %{"ref" => "b"},
             "base" => %{"ref" => "main"},
             "user" => %{"login" => "ravix[bot]"}
           })
         end}
      ])

      creator = insert_user(login: "maker")
      project = insert_project(user: creator, repo_full_name: "acme/app", installation_id: 5)
      track = insert_track(project: project, created_by: creator.id)
      %{creator: creator, track: track}
    end

    test "the body names the track starter", ctx do
      switch(true)
      assert {:ok, _} = Tracks.open_pull(ctx.creator, ctx.track.id, %{"body" => "Fixes it."})
      assert_receive {:pull_body, "Fixes it.\n\nTrack started by @maker in Ravix."}
    end

    test "with the switch off the body is as given", ctx do
      switch(false)
      assert {:ok, _} = Tracks.open_pull(ctx.creator, ctx.track.id, %{"body" => "Fixes it."})
      assert_receive {:pull_body, "Fixes it."}
    end
  end
end
