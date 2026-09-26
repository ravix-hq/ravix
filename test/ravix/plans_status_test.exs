defmodule Ravix.PlansStatusTest do
  use Ravix.DataCase, async: true
  use Mimic
  alias Ravix.{GitHub, Plans}
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

    stub(GitHub, :pull_for_track, fn _, _, _, branch, _ ->
      case branch do
        "branch-a" -> {:ok, %{state: :merged}}
        "branch-c" -> {:ok, %{state: :open}}
        "branch-d" -> {:ok, %{state: :closed}}
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
         "o:" <> branch = conn.query_params["head"]

         Req.Test.json(conn, [
           %{
             number: 1,
             head: %{ref: branch},
             state: "closed",
             created_at: "2030-01-01T00:00:00Z",
             merged_at: "2030-01-02T00:00:00Z"
           }
         ])
       end}
    ])

    assert {:ok, %{items: items}} = Plans.get(user, plan.id)
    assert Enum.all?(items, &(&1.status == :done and &1.status_available))
    assert Ravix.GitHubFake.request_count("/repos/") == 12
    assert {:ok, %{items: ^items}} = Plans.get(user, plan.id)
    assert Ravix.GitHubFake.request_count() == 0
  end
end
