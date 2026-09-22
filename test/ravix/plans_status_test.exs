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

    stub(GitHub, :checks, fn _, _, _, branch, _ ->
      case branch do
        "branch-a" -> {:ok, %{pull: %{state: :merged}}}
        "branch-c" -> {:ok, %{pull: %{state: :open}}}
        "branch-d" -> {:ok, %{pull: %{state: :closed}}}
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
end
