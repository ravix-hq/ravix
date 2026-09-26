defmodule Ravix.PlansProgressTest do
  use Ravix.DataCase, async: true
  use Mimic
  alias Ravix.{GitHub, GitHubFake, Plans}
  alias Ravix.Plans.Progress

  test "all statuses count once; closed is not completed and empty plans are zero percent" do
    statuses = [
      :done,
      :done,
      :in_review,
      :in_progress,
      :unassigned,
      :ready,
      :blocked,
      :closed_without_merge
    ]

    assert Progress.summarize(Enum.map(statuses, &%{status: &1})) ==
             %{done: 2, wip: 2, unstarted: 3, blocked: 1, total: 8, percent: 25}

    assert Progress.summarize([]) == %{
             done: 0,
             wip: 0,
             unstarted: 0,
             blocked: 0,
             total: 0,
             percent: 0
           }

    assert Progress.summarize([%{status: :done}, %{status: :ready}, %{status: :ready}]).percent ==
             33
  end

  test "several plans share one repository batch, including dependency status" do
    user = insert_user()
    project = insert_project(user: user, repo_full_name: "o/r")
    app = GitHubFake.app()
    stub(Ravix.Config, :github, fn -> app end)

    GitHubFake.install([
      GitHubFake.token_route(app),
      {"GET", "/repos/o/r/pulls",
       [
         %{
           number: 1,
           state: "closed",
           merged_at: "2026-09-26T00:00:00Z",
           body: "Plan-Item: done-a\nPlan-Item: done-b",
           head: %{ref: "other", repo: %{full_name: "o/r"}}
         }
       ]}
    ])

    for suffix <- ~w(a b) do
      {:ok, _} =
        Plans.create(user, project.id, %{
          "title" => suffix,
          "items" => [
            %{"id" => "done-#{suffix}", "title" => "Done"},
            %{"id" => "ready-#{suffix}", "title" => "Ready", "dependencies" => ["done-#{suffix}"]}
          ]
        })
    end

    reject(GitHub, :pull_for_track, 5)
    assert {:ok, plans} = Plans.list_with_progress(user, project.id)
    assert length(plans) == 2

    assert Enum.all?(
             plans,
             &(&1.progress == %{done: 1, wip: 0, unstarted: 1, blocked: 0, total: 2, percent: 50})
           )

    assert GitHubFake.request_count("/repos/") == 1
    assert {:ok, ^plans} = Plans.list_with_progress(user, project.id)
    assert GitHubFake.request_count() == 0
    assert {:error, :not_found} = Plans.list_with_progress(insert_user(), project.id)
  end
end
