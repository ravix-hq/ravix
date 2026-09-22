defmodule Ravix.PlansTest do
  use Ravix.DataCase, async: true
  alias Ravix.Plans
  alias Ravix.Plans.{Graph, Item, Prompt, Status}

  test "project members edit; guests only see their assigned item's material" do
    owner = insert_user()
    member = insert_user()
    guest = insert_user()
    stranger = insert_user()
    project = insert_project(user: owner)
    insert_project_member(project, member)
    track = insert_track(project: project)
    insert_track_member(track, guest)

    {:ok, plan} =
      Plans.create(member, project.id, %{
        "title" => "Release",
        "summary" => "private rationale",
        "items" => [
          %{"id" => "one", "title" => "First"},
          %{"id" => "two", "title" => "Secret sibling"}
        ]
      })

    {:ok, %{items: [first, _]}} = Plans.get(owner, plan.id)
    first_row = Repo.get!(Item, first.id)
    Repo.update!(Ecto.Changeset.change(first_row, track_id: track.id))
    assert {:ok, [%{title: "Release"}]} = Plans.list(member, project.id)
    assert {:error, :not_found} = Plans.get(guest, plan.id)
    assert {:error, :not_found} = Plans.list(guest, project.id)
    assert {:error, :not_found} = Plans.get(stranger, plan.id)
    assert {:error, :not_found} = Plans.update(stranger, plan.id, 1, %{"title" => "stolen"})
    assert {:ok, [item]} = Plans.track_items(guest, track.id)
    refute Map.has_key?(item, :dependencies)
    refute Map.has_key?(item, :plan_id)
    assert {:ok, _} = Plans.note(guest, first.id, "Observed a failing check")
    assert {:error, :not_found} = Plans.note(guest, "two", "hidden")
    assert {:error, :not_found} = Plans.note(stranger, first.id, "hidden")
    assert {:error, :not_found} = Plans.track_items(stranger, track.id)
  end

  test "edits carry versions and dependency changes are atomic" do
    user = insert_user()
    project = insert_project(user: user)

    {:ok, plan} =
      Plans.create(user, project.id, %{
        "title" => "Ship",
        "items" => [%{"id" => "a", "title" => "A"}]
      })

    assert {:ok, %{version: 2, archived: true}} =
             Plans.update(user, plan.id, 1, %{
               "archived" => true,
               "items" => [
                 %{"id" => "a", "title" => "Edited"},
                 %{"id" => "b", "title" => "B", "dependencies" => ["a"]}
               ]
             })

    assert {:error, {:conflict, "stale_version", _}} =
             Plans.update(user, plan.id, 1, %{"title" => "stale"})

    assert {:error, {:unprocessable, "invalid_dependencies", _}} =
             Plans.update(user, plan.id, 2, %{
               "items" => [
                 %{"id" => "a", "title" => "A", "dependencies" => ["b"]},
                 %{"id" => "b", "title" => "B", "dependencies" => ["a"]}
               ]
             })

    assert {:ok, %{plan: %{version: 2}, items: [%{title: "Edited"}, _]}} =
             Plans.get(user, plan.id)

    assert {:ok, _} = Plans.update(user, plan.id, 2, %{"items" => []})
    assert {:ok, %{items: []}} = Plans.get(user, plan.id)
  end

  test "invalid fields, foreign dependencies and foreign item IDs are refused" do
    user = insert_user()
    project = insert_project(user: user)
    assert {:error, %Ecto.Changeset{}} = Plans.create(user, project.id, %{"title" => ""})

    assert {:error, {:unprocessable, "invalid_dependencies", _}} =
             Plans.create(user, project.id, %{
               "title" => "Bad",
               "items" => [%{"title" => "A", "dependencies" => ["outside"]}]
             })

    assert {:error, {:unprocessable, "invalid_items", _}} =
             Plans.create(user, project.id, %{"title" => "Bad", "items" => nil})

    assert {:error, %Ecto.Changeset{}} =
             Plans.create(user, project.id, %{"title" => "Bad", "items" => [%{}]})

    assert {:error, :not_found} = Plans.get(user, "missing")
    assert {:error, :not_found} = Plans.note(user, "missing", "hello")

    # An item id another plan already holds is refused, not raised.
    {:ok, _} =
      Plans.create(user, project.id, %{
        "title" => "One",
        "items" => [%{"id" => "x", "title" => "X"}]
      })

    assert {:error, %Ecto.Changeset{errors: [id: _]}} =
             Plans.create(user, project.id, %{
               "title" => "Two",
               "items" => [%{"id" => "x", "title" => "X"}]
             })

    assert {:error, {:unprocessable, _, _}} =
             Graph.validate([%Item{id: "a", dependencies: []}, %Item{id: "a", dependencies: []}])
  end

  test "assigned items cannot be rewritten or removed, and agent provenance is scoped" do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project)

    {:ok, plan} =
      Plans.create(
        user,
        project.id,
        %{"title" => "Work", "items" => [%{"id" => "x", "title" => "X"}]},
        {:track_agent, track.id}
      )

    assert plan.created_by_track_id == track.id
    item = Repo.get!(Item, "x") |> Ecto.Changeset.change(track_id: track.id) |> Repo.update!()

    assert {:error, {:conflict, "item_assigned", _}} =
             Plans.update(user, plan.id, 1, %{"items" => []})

    assert {:error, {:conflict, "item_assigned", _}} =
             Plans.update(user, plan.id, 1, %{
               "items" => [%{"id" => item.id, "title" => "Different"}]
             })

    assert {:ok, _} =
             Plans.update(user, plan.id, 1, %{"items" => [%{"id" => item.id, "title" => "X"}]})

    assert {:ok, %{created_by_track_id: id}} =
             Plans.note(user, item.id, "Agent note", {:track_agent, track.id})

    assert id == track.id
    other = insert_track()

    assert {:error, :not_found} =
             Plans.create(user, project.id, %{"title" => "Wrong"}, {:track_agent, other.id})
  end

  test "all statuses follow tracks and PR evidence, and prompts state parallel scope" do
    item = %Item{
      id: "a",
      title: "API",
      brief: "Implement API",
      acceptance: "Test it",
      dependencies: []
    }

    assert Status.derive(item, nil, nil, MapSet.new()) == :unassigned
    blocked = %{item | dependencies: ["b"]}
    assert Status.derive(blocked, nil, nil, MapSet.new()) == :blocked
    assert Status.derive(blocked, nil, nil, MapSet.new(["b"])) == :ready
    assert Status.derive(item, %{closed_at: nil}, nil, MapSet.new()) == :in_progress

    assert Status.derive(item, %{closed_at: DateTime.utc_now()}, nil, MapSet.new()) ==
             :closed_without_merge

    for {state, expected} <- [open: :in_review, merged: :done, closed: :closed_without_merge] do
      assert Status.derive(blocked, %{closed_at: nil}, %{pull: %{state: state}}, MapSet.new()) ==
               expected
    end

    prompt =
      Prompt.build(%{title: "Launch", summary: "Why now"}, item, [
        item,
        %{item | id: "b", title: "UI", brief: "Own the interface", track_id: "track-b"}
      ])

    for text <- [
          "Why now",
          "Implement API",
          "Test it",
          "track-b",
          "Own the interface",
          "rebase",
          "draft PR",
          "Do not merge"
        ],
        do: assert(prompt =~ text)
  end
end
