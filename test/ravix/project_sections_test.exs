defmodule Ravix.ProjectSectionsTest do
  use Ravix.DataCase, async: true

  alias Ravix.Projects.Sections

  test "sections persist names, collapse state and exclusive project placement" do
    user = insert_user()
    project = insert_project(user: user)
    assert {:ok, first} = Sections.create(user, %{name: " Work "})
    assert first.name == "Work"
    assert {:ok, second} = Sections.create(user, %{name: "Later"})
    assert {:ok, _} = Sections.move(user, project.id, first.id)
    assert {:ok, _} = Sections.move(user, project.id, second.id)
    assert {:ok, _} = Sections.update(user, second.id, %{name: "Soon", collapsed: true})
    {sections, placements} = Sections.list(user)
    assert placements == %{project.id => second.id}
    assert Enum.find(sections, &(&1.id == second.id)).collapsed
    assert {:ok, _} = Sections.move(user, project.id, "")
    assert {_, %{}} = Sections.list(user)
    assert {:ok, _} = Sections.move(user, project.id, second.id)
    assert {:ok, _} = Sections.delete(user, second.id)
    assert {[^first], %{}} = Sections.list(user)
    assert Ravix.Projects.get(user, project.id) |> elem(0) == :ok
  end

  test "names are required, bounded and unique per person" do
    user = insert_user()
    assert {:error, _} = Sections.create(user, %{name: "   "})
    assert {:error, _} = Sections.create(user, %{name: String.duplicate("x", 81)})
    assert {:ok, _} = Sections.create(user, %{name: "Work"})
    assert {:error, _} = Sections.create(user, %{name: "Work"})
    assert {:ok, _} = Sections.create(insert_user(), %{name: "Work"})
  end

  test "foreign sections and inaccessible projects cannot be changed" do
    user = insert_user()
    other = insert_user()
    project = insert_project(user: user)
    foreign = insert_project(user: other)
    {:ok, own} = Sections.create(user, %{name: "Mine"})
    {:ok, theirs} = Sections.create(other, %{name: "Theirs"})
    assert {:error, :not_found} = Sections.update(user, theirs.id, %{name: "Stolen"})
    assert {:error, :not_found} = Sections.delete(user, theirs.id)
    assert {:error, :not_found} = Sections.move(user, project.id, theirs.id)
    assert {:error, :not_found} = Sections.move(user, foreign.id, own.id)
    assert {:error, :not_found} = Sections.move(user, foreign.id, "")
    assert {[^theirs], %{}} = Sections.list(other)
  end

  test "project and track guests organize independently and lose move access on revocation" do
    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project)
    member = insert_user()
    guest = insert_user()
    insert_project_member(project, member)
    membership = insert_track_member(track, guest)

    for user <- [owner, member, guest] do
      {:ok, section} = Sections.create(user, %{name: "Work"})
      assert {:ok, _} = Sections.move(user, project.id, section.id)
      assert {[section], %{project.id => section.id}} == Sections.list(user)
    end

    Repo.delete!(membership)
    assert {:error, :not_found} = Sections.move(guest, project.id, "")
  end
end
