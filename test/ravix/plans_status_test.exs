defmodule Ravix.PlansStatusTest do
  use Ravix.DataCase, async: true
  use Mimic
  alias Ravix.{GitHub, Plans}
  alias Ravix.GitHub.Shapes
  alias Ravix.Plans.Item

  test "cached GitHub evidence completes dependencies and flags provider failure" do
    user = insert_user()
    project = insert_project(user: user)

    {:ok, plan} =
      Plans.create(user, project.id, %{
        "title" => "Review",
        "items" => [
          %{"id" => "a", "title" => "A"},
          %{"id" => "b", "title" => "B", "dependencies" => ["a"]},
          %{"id" => "c", "title" => "C"},
          %{"id" => "d", "title" => "D"},
          %{"id" => "e", "title" => "E"}
        ]
      })

    for id <- ~w(a c d e) do
      track = insert_track(project: project, branch: "branch-#{id}")
      Repo.get!(Item, id) |> Ecto.Changeset.change(track_id: track.id) |> Repo.update!()
    end

    stub(Ravix.Config, :github, fn -> Ravix.GitHubFake.app() end)

    stub(GitHub, :plan_pulls, fn _, _, _ -> {:ok, %{pulls: [], complete: true}} end)

    stub(GitHub, :pull_for_track, fn _, _, _, branch, _ ->
      case branch do
        "branch-a" -> {:ok, pull(1, :merged)}
        "branch-c" -> {:ok, pull(2, :open)}
        "branch-d" -> {:ok, pull(3, :closed)}
        "branch-e" -> {:error, :unavailable}
      end
    end)

    assert {:ok, %{items: [a, b, c, d, e]}} = Plans.get(user, plan.id)
    assert a.status == :done
    assert b.status == :ready
    assert c.status == :in_review
    assert d.status == :closed_without_merge
    assert e.status == :in_progress
    refute e.status_available
    assert a.track_url =~ "/p/#{project.id}/t/"
  end

  test "a cold plan reads only PRs and a second read uses cached evidence" do
    user = insert_user()
    project = insert_project(user: user, repo_full_name: "o/r")
    ids = Enum.map(1..12, &"item-#{&1}")

    {:ok, plan} =
      Plans.create(user, project.id, %{
        "title" => "Batch",
        "items" => Enum.map(ids, &%{"id" => &1, "title" => &1})
      })

    for id <- ids do
      track = insert_track(project: project, branch: id)
      Repo.get!(Item, id) |> Ecto.Changeset.change(track_id: track.id) |> Repo.update!()
    end

    app = Ravix.GitHubFake.app()
    stub(Ravix.Config, :github, fn -> app end)

    Ravix.GitHubFake.install([
      Ravix.GitHubFake.token_route(app),
      {"GET", "/repos/o/r/pulls",
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)
         branch = String.replace_prefix(conn.query_params["head"] || "", "o:", "")

         Req.Test.json(
           conn,
           if(branch == "",
             do: [],
             else: [
               %{
                 number: 1,
                 head: %{ref: branch},
                 state: "closed",
                 created_at: "2030-01-01T00:00:00Z",
                 merged_at: "2030-01-02T00:00:00Z"
               }
             ]
           )
         )
       end}
    ])

    assert {:ok, %{items: items}} = Plans.get(user, plan.id)
    assert Enum.all?(items, &(&1.status == :done and &1.status_available))
    assert Ravix.GitHubFake.request_count("/repos/") == 13
    assert {:ok, %{items: ^items}} = Plans.get(user, plan.id)
    assert Ravix.GitHubFake.request_count() == 0
    track_id = hd(items).track_url |> String.split("/t/") |> List.last()
    guest = insert_user()
    insert_track_member(Repo.get!(Ravix.Tracks.Track, track_id), guest)
    assert {:ok, %{items: [assigned], plan: nil}} = Plans.track_summary(guest, track_id)
    assert assigned.status == :done
    assert assigned.pull.number == 1
    refute Map.has_key?(assigned, :dependencies)
    assert Ravix.GitHubFake.request_count() == 0
    assert {:ok, %{plan: %{title: "Batch"}}} = Plans.track_summary(user, track_id)
    assert {:error, :not_found} = Plans.track_summary(insert_user(), track_id)
  end

  test "item trailers override a merged track PR and dependencies use each item's evidence" do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project)

    {:ok, plan} =
      Plans.create(user, project.id, %{
        "title" => "Per item",
        "items" => [
          %{"id" => "legacy", "title" => "Legacy"},
          %{"id" => "open", "title" => "Own open PR"},
          %{"id" => "merged", "title" => "Other branch merged"},
          %{"id" => "blocked", "title" => "Wait for open", "dependencies" => ["open"]},
          %{"id" => "ready", "title" => "Wait for merged", "dependencies" => ["merged"]},
          %{"id" => "closed", "title" => "Closed PRs"},
          %{"id" => "multiple", "title" => "Several PRs"}
        ]
      })

    for id <- ~w(legacy open merged closed multiple) do
      Repo.get!(Item, id) |> Ecto.Changeset.change(track_id: track.id) |> Repo.update!()
    end

    app = Ravix.GitHubFake.app()
    stub(Ravix.Config, :github, fn -> app end)
    stub(GitHub, :pull_for_track, fn _, _, _, _, _ -> {:ok, pull(218, :merged)} end)

    linked = [
      pull(225, :open, ["open", "multiple"]),
      pull(219, :merged, ["merged"]),
      pull(220, :closed, ["closed", "multiple"]),
      pull(221, :closed, ["closed"])
    ]

    stub(GitHub, :plan_pulls, fn _, _, _ -> {:ok, %{pulls: linked, complete: true}} end)
    assert {:ok, %{items: [a, b, c, d, e, f, g]}} = Plans.get(user, plan.id)
    assert {a.status, b.status, c.status} == {:done, :in_review, :done}
    assert {a.pull.number, b.pull.number, c.pull.number} == {218, 225, 219}

    assert {d.status, e.status, f.status, g.status} ==
             {:blocked, :ready, :closed_without_merge, :in_review}

    linked = [pull(226, :merged, ["open", "multiple"]) | linked]
    stub(GitHub, :plan_pulls, fn _, _, _ -> {:ok, %{pulls: linked, complete: true}} end)
    assert {:ok, %{items: [_, b, _, d, _, _, g]}} = Plans.get(user, plan.id)
    assert {b.status, d.status, g.status, g.pull.number} == {:done, :ready, :done, 226}
  end

  test "unavailable or capped item lookup cannot falsely complete an item via fallback" do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project)

    {:ok, plan} =
      Plans.create(user, project.id, %{
        "title" => "Incomplete",
        "items" => [%{"id" => "unknown", "title" => "Unknown"}]
      })

    Repo.get!(Item, "unknown") |> Ecto.Changeset.change(track_id: track.id) |> Repo.update!()
    stub(Ravix.Config, :github, fn -> Ravix.GitHubFake.app() end)
    reject(GitHub, :pull_for_track, 5)

    for result <- [
          {:error, :unavailable},
          {:ok, %{pulls: [], complete: false}},
          {:ok, %{pulls: [pull(227, :open, ["unknown"])], complete: false}},
          {:ok, %{pulls: [pull(228, :closed, ["unknown"])], complete: false}}
        ] do
      stub(GitHub, :plan_pulls, fn _, _, _ -> result end)
      assert {:ok, %{items: [item]}} = Plans.get(user, plan.id)
      assert item.status == :in_progress
      refute item.status_available
      assert item.pull == nil
    end
  end

  test "a merged link is decisive even when the repository scan is capped" do
    user = insert_user()
    project = insert_project(user: user)

    {:ok, plan} =
      Plans.create(user, project.id, %{
        "title" => "Merged",
        "items" => [%{"id" => "merged-capped", "title" => "Merged"}]
      })

    stub(Ravix.Config, :github, fn -> Ravix.GitHubFake.app() end)

    stub(GitHub, :plan_pulls, fn _, _, _ ->
      {:ok, %{pulls: [pull(229, :merged, ["merged-capped"])], complete: false}}
    end)

    reject(GitHub, :pull_for_track, 5)
    assert {:ok, %{items: [item]}} = Plans.get(user, plan.id)
    assert item.status == :done
    assert item.status_available
    assert item.pull.number == 229
  end

  test "N linked items on one track use one repository request and no per-item fallback reads" do
    user = insert_user()
    project = insert_project(user: user, repo_full_name: "o/r")
    track = insert_track(project: project)
    ids = Enum.map(1..30, &"batch-#{&1}")

    {:ok, plan} =
      Plans.create(user, project.id, %{
        "title" => "Shared track",
        "items" => Enum.map(ids, &%{"id" => &1, "title" => &1})
      })

    for id <- ids do
      Repo.get!(Item, id) |> Ecto.Changeset.change(track_id: track.id) |> Repo.update!()
    end

    app = Ravix.GitHubFake.app()
    stub(Ravix.Config, :github, fn -> app end)

    Ravix.GitHubFake.install([
      Ravix.GitHubFake.token_route(app),
      {"GET", "/repos/o/r/pulls",
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)
         refute Map.has_key?(conn.query_params, "head")

         Req.Test.json(conn, [
           %{
             number: 225,
             state: "open",
             body: Enum.map_join(ids, "\n", &"Plan-Item: #{&1}"),
             head: %{ref: "item-branch", repo: %{full_name: "o/r"}}
           }
         ])
       end}
    ])

    assert {:ok, %{items: items}} = Plans.get(user, plan.id)
    assert length(items) == 30
    assert Enum.all?(items, &(&1.status == :in_review and &1.pull.number == 225))
    assert Ravix.GitHubFake.request_count("/repos/") == 1
    assert {:ok, %{items: ^items}} = Plans.get(user, plan.id)
    assert Ravix.GitHubFake.request_count() == 0
  end

  defp pull(number, state, ids \\ []) do
    Shapes.pull_ref(%{
      "number" => number,
      "state" => if(state == :open, do: "open", else: "closed"),
      "merged_at" => if(state == :merged, do: "2030-01-01T00:00:00Z"),
      "head" => %{"ref" => "item-#{number}", "repo" => %{"full_name" => "o/r"}},
      "html_url" => "https://github.com/o/r/pull/#{number}",
      "body" => Enum.map_join(ids, "\n", &"Plan-Item: #{&1}")
    })
  end
end
