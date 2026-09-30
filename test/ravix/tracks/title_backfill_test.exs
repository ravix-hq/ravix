defmodule Ravix.Tracks.TitleBackfillTest do
  use Ravix.DataCase, async: true

  alias Ravix.PromptQueue.Store, as: Queue
  alias Ravix.Tracks.{Thread, TitleBackfill, Track}

  setup do
    user = insert_user(login: "owner")
    %{user: user, project: insert_project(user: user)}
  end

  defp branch_titled(ctx, name, attrs \\ []),
    do:
      insert_track(
        [project: ctx.project, title: "ravix/#{name}", branch: "ravix/#{name}"] ++ attrs
      )

  defp prompt(ctx, track, text) do
    {:ok, _} =
      Queue.enqueue(
        track.id,
        ctx.user.id,
        ctx.user.login,
        Ecto.UUID.generate(),
        %{prompt: text},
        track.id
      )
  end

  defp thread!(track, changes),
    do: Repo.get!(Thread, track.id) |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp track(id), do: Repo.get!(Track, id)
  defp actions(%{tracks: lines}), do: Map.new(lines, &{&1.id, &1.action})

  test "titles open tracks still called by their branch, and a second run changes nothing", ctx do
    # Opened by Ravix over MCP: its opening turn first, then the person's words.
    asked = branch_titled(ctx, "crewe")
    prompt(ctx, asked, "[ravix] Open this track. Make its working directory, then stop.")
    prompt(ctx, asked, "Can you pull the latest main and fix the conflicts?")

    # The runtime titled the thread, but the track never took it.
    adopted = branch_titled(ctx, "didcot")
    thread!(adopted, title: "Fix the Build", title_source: :auto)

    silent = branch_titled(ctx, "ely")
    wordless = branch_titled(ctx, "frome")
    prompt(ctx, wordless, "   ")
    named_thread = branch_titled(ctx, "goole")
    thread!(named_thread, title: "Ledger", title_source: :manual)

    # Not candidates: a person's name, a title already automatic, a closed track.
    renamed = branch_titled(ctx, "hull", title: "Ledger cleanup", title_source: :manual)
    closed = branch_titled(ctx, "ilkley", closed_at: DateTime.utc_now())
    prompt(ctx, closed, "Fix the login redirect")

    assert {:ok, dry} = TitleBackfill.run()
    refute dry.applied

    assert actions(dry) == %{
             asked.id => :retitle,
             adopted.id => :retitle,
             silent.id => :no_prompt,
             wordless.id => :no_words,
             named_thread.id => :thread_named
           }

    # A dry run writes nothing, and says no title out loud.
    assert track(asked.id).title == "ravix/crewe"
    output = Enum.join(TitleBackfill.format(dry), "\n")
    assert output =~ "Dry run (pass --apply to write): 1 no_prompt, 1 no_words, 2 retitle,"
    refute output =~ "Pull Latest Main"
    refute output =~ "Fix the Build"

    assert {:ok, applied} = TitleBackfill.run(apply: true)
    assert Enum.find(applied.tracks, &(&1.id == asked.id)).result == :retitled
    assert Enum.join(TitleBackfill.format(applied), "\n") =~ "#{asked.id} (project "

    assert %{title: "Pull Latest Main", title_source: :auto, branch: "ravix/crewe"} =
             track(asked.id)

    assert %{title: "Pull Latest Main", title_source: :auto} = Repo.get!(Thread, asked.id)
    assert %{title: "Fix the Build", title_source: :auto} = track(adopted.id)

    for id <- [silent.id, wordless.id, named_thread.id, closed.id],
        do: assert(track(id).title_source == nil)

    assert track(renamed.id).title == "Ledger cleanup"
    assert track(closed.id).title == "ravix/ilkley"

    assert {:ok, again} = TitleBackfill.run(apply: true)
    refute Map.has_key?(actions(again), asked.id)
    refute Map.has_key?(actions(again), adopted.id)
  end

  test "a track renamed after a dry run keeps its name, and a stale write is reported", ctx do
    track = branch_titled(ctx, "jarrow")
    prompt(ctx, track, "Fix the login redirect")
    {:ok, %{tracks: [line]}} = TitleBackfill.run()

    Repo.update!(Ecto.Changeset.change(track(track.id), title: "Mine", title_source: :manual))

    # Every run plans afresh, so the renamed track is no longer a candidate.
    # A rename landing between a run's plan and its write meets
    # `Store.auto_title/3`'s compare-and-set, and is reported as below.
    assert {:ok, %{tracks: []}} = TitleBackfill.run(apply: true)
    assert track(track.id).title == "Mine"
    assert line.action == :retitle

    assert TitleBackfill.format(%{applied: true, tracks: [%{line | result: :stale}]}) == [
             "Applied: 1 retitle",
             "  #{track.id} (project #{ctx.project.id}): retitle -> " <>
               "skipped at write: renamed or retitled since the plan"
           ]
  end

  test "reports an empty plan" do
    assert {:ok, summary} = TitleBackfill.run(apply: true)

    assert TitleBackfill.format(summary) == [
             "Applied: no open track is still titled with its branch"
           ]
  end
end
