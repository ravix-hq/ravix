defmodule Ravix.ProjectsLabelTest do
  @moduledoc """
  RAV-128: a project's name is read against the container it lives in, and
  only where the viewer is not already inside it. A workspace project is
  its workspace's, the same for its creator and every other member; a
  legacy project is still its owner's (ADR 0005), as #163 drew it.

  Not async: the tests turn `RAVIX_WORKSPACE_ACCESS` on and off, application-wide.
  """
  use Ravix.DataCase, async: false
  @moduletag :deprecated_literal_ui

  alias Ravix.Accounts.Access
  alias Ravix.Projects
  alias Ravix.Projects.{Machine, View}
  alias Ravix.QueryCount
  alias Ravix.Workspaces
  alias Ravix.Workspaces.Store

  setup do
    previous = Application.fetch_env(:ravix, :workspace_access)
    Application.put_env(:ravix, :workspace_access, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :workspace_access, value)
        :error -> Application.delete_env(:ravix, :workspace_access)
      end
    end)

    creator = insert_user(login: "creator")
    {:ok, personal} = Store.ensure_personal_workspace(creator)
    {:ok, acme} = Workspaces.create(creator, "Acme")
    mate = insert_user(login: "mate")
    :ok = Store.add_member(acme.id, mate.id, :member, creator.id)

    app = insert_project(user: creator, name: "app", repo_full_name: "acme/app")
    1 = Store.move_project(app.id, acme.id)
    app = Repo.reload!(app)

    %{creator: creator, mate: mate, personal: personal, acme: acme, app: app}
  end

  defp switch(on?), do: Application.put_env(:ravix, :workspace_access, on?)

  defp view_of(user, project) do
    assert {:ok, view} = Projects.get(user, project.id)

    assert [listed] =
             Enum.filter(Projects.list(user, include_machine: false), &(&1.id == project.id))

    # The rail and the project page cannot disagree about the name.
    assert listed.display_name == view.display_name
    assert {listed.container, listed.container_id} == {view.container, view.container_id}
    view
  end

  describe "a workspace project" do
    test "reads the same for its creator and every other member: bare inside, prefixed across",
         ctx do
      for {user, role} <- [{ctx.creator, :owner}, {ctx.mate, :member}] do
        view = view_of(user, ctx.app)
        assert view.role == role
        assert view.name == "app"
        assert view.container == "Acme"
        assert view.container_id == ctx.acme.id
        # A surface that spans workspaces names the workspace.
        assert view.display_name == "Acme / app"
        assert View.label(view) == "Acme / app"
        assert View.prefix(view, nil) == "Acme"
        # A surface inside the workspace reads the bare name.
        assert View.label(view, ctx.acme.id) == "app"
        assert View.prefix(view, ctx.acme.id) == nil
        # Another workspace's surface is outside it.
        assert View.label(view, ctx.personal.id) == "Acme / app"
      end
    end

    test "keeps legacy labelling for somebody who reaches it without the workspace", ctx do
      legacy = insert_user(login: "legacy")
      insert_project_member(ctx.app, legacy)

      view = view_of(legacy, ctx.app)
      assert view.access == :project
      assert view.container == "creator"
      assert view.container_id == nil
      assert view.display_name == "creator / app"
      # A person is not a place anybody is inside: the prefix stays whatever
      # the surface is scoped to, including the project's own workspace.
      assert View.label(view, ctx.acme.id) == "creator / app"
    end

    test "keeps legacy labelling while the switch is off", ctx do
      legacy = insert_user(login: "legacy")
      insert_project_member(ctx.app, legacy)
      switch(false)

      assert view_of(ctx.creator, ctx.app).display_name == "app"
      assert view_of(ctx.creator, ctx.app).container == nil
      assert view_of(legacy, ctx.app).display_name == "creator / app"
      assert view_of(legacy, ctx.app).container_id == nil
      # The membership does not count, so there is nothing to label.
      assert Projects.get(ctx.mate, ctx.app.id) == {:error, :not_found}
      assert Projects.list(ctx.mate, include_machine: false) == []
    end

    test "in a personal workspace reads bare everywhere, never behind its own login", ctx do
      mine = insert_project(user: ctx.creator, name: "mine")
      1 = Store.move_project(mine.id, ctx.personal.id)

      view = view_of(ctx.creator, Repo.reload!(mine))
      assert view.workspace_id == ctx.personal.id
      assert view.container == nil
      assert view.container_id == nil
      assert view.display_name == "mine"
      assert View.label(view, ctx.acme.id) == "mine"
    end

    test "is named without a workspace read per row when the rail lists several", ctx do
      {_, one} = QueryCount.count(fn -> Projects.list(ctx.mate, include_machine: false) end)

      for name <- ~w(two three four),
          do:
            1 = Store.move_project(insert_project(user: ctx.creator, name: name).id, ctx.acme.id)

      {listed, several} =
        QueryCount.count(fn -> Projects.list(ctx.mate, include_machine: false) end)

      assert Enum.map(listed, & &1.display_name) ==
               ["Acme / app", "Acme / two", "Acme / three", "Acme / four"]

      assert length(several) == length(one)

      # Which is what `workspace_reach/1` carries for it.
      assert %{workspaces: [%{id: id, name: "Acme"}], workspace_ids: [id]} =
               Access.workspace_reach(ctx.mate) |> Map.take([:workspaces, :workspace_ids])

      assert id == ctx.acme.id
    end
  end

  describe "a legacy project" do
    test "is still its owner's: bare for the owner, 'owner / name' for anybody it is shared with",
         ctx do
      shared = insert_project(user: ctx.creator, name: "shared")
      insert_project_member(shared, ctx.mate)

      owner = view_of(ctx.creator, shared)
      assert {owner.container, owner.container_id} == {nil, nil}
      assert owner.display_name == "shared"

      member = view_of(ctx.mate, shared)
      assert {member.container, member.container_id} == {"creator", nil}
      assert member.display_name == "creator / shared"
      # Wherever it is drawn, Acme or personal.
      assert View.label(member, ctx.acme.id) == "creator / shared"
      assert View.label(member, ctx.personal.id) == "creator / shared"
    end

    test "with an owner who has no login reads bare, not behind an empty prefix", ctx do
      orphan = Projects.present(ctx.app, :project, Machine.none(), nil)
      assert {orphan.container, orphan.container_id} == {nil, nil}
      assert orphan.display_name == "app"

      nameless = Projects.present(ctx.app, :project, Machine.none(), %{ctx.creator | login: nil})
      assert nameless.display_name == "app"
    end
  end

  test "present/5 given the workspace reads against it, and without one reads the legacy way",
       ctx do
    with_workspace = Projects.present(ctx.app, :project, Machine.none(), ctx.creator, ctx.acme)
    assert with_workspace.display_name == "Acme / app"
    assert with_workspace.container_id == ctx.acme.id

    without = Projects.present(ctx.app, :project, Machine.none(), ctx.creator)
    assert without.display_name == "creator / app"
    assert without.container_id == nil

    # A workspace that is not the project's is not its container.
    {:ok, other} = Workspaces.create(ctx.creator, "Other")

    assert Projects.present(ctx.app, :project, Machine.none(), ctx.creator, other).container ==
             "creator"
  end
end
