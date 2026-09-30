defmodule RavixWeb.SettingsAccessTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.Fountain.Shapes.Catalog
  import Ecto.Query

  test "members and unrelated users cannot open settings", %{conn: conn} do
    owner = insert_user()
    project = insert_project(user: owner)
    member = insert_user()
    insert_project_member(project, member)

    {:ok, view, _} = live(log_in_user(conn, member), "/p/#{project.id}")
    render_patch(view, "/p/#{project.id}/settings/general")
    refute has_element?(view, "#settings-form")

    {:ok, stranger, _} = live(log_in_user(conn, insert_user()), "/p/#{project.id}")
    render_async(stranger)
    assert_patch(stranger, "/home")
    assert has_element?(stranger, "#flash-info", "Project not found.")
  end

  for revoked <- [false, true] do
    test "orphan cleanup hides metadata and checks sessions (revoked: #{revoked})", %{conn: conn} do
      owner = insert_user()
      creator = insert_user()
      project = insert_project(user: owner)
      insert_project_member(project, creator)

      track =
        insert_track(
          project: project,
          created_by: creator.id,
          visibility: :private,
          sandbox_layout: :dedicated,
          sandbox_state: :ready,
          sandbox_id: "orphan-machine",
          title: "Secret orphan title"
        )

      stub(Ravix.Projects, :settings, fn _, _ ->
        {:ok,
         %{
           name: project.name,
           runtime: "claude",
           model: "model",
           instructions: "",
           setup_script: "",
           packages: %{},
           env_keys: [],
           vault_keys: [],
           catalog: Catalog.empty()
         }}
      end)

      assert {:ok, _} = Ravix.People.remove_project(owner, project.id, creator.login)
      {:ok, view, _} = live(log_in_user(conn, owner), "/p/#{project.id}")
      render_async(view)
      render_patch(view, "/p/#{project.id}/settings/danger")
      render_async(view)

      assert has_element?(
               view,
               "#close-orphaned-private-form",
               "1 private tracks with no remaining members"
             )

      refute render(view) =~ track.title
      refute render(view) =~ track.branch
      view |> form("#close-orphaned-private-form", confirm: "wrong") |> render_submit()
      assert Ravix.Repo.get!(Ravix.Tracks.Track, track.id).sandbox_state == :ready

      if unquote(revoked) do
        Ravix.Repo.delete_all(from(s in Ravix.Accounts.Session, where: s.user_id == ^owner.id))

        :sys.replace_state(view.pid, fn state ->
          update_in(state.socket.assigns.session_guard, &%{&1 | stale?: true})
        end)

        assert {:error, {:redirect, %{to: "/login"}}} =
                 view
                 |> form("#close-orphaned-private-form", confirm: project.name)
                 |> render_submit()

        assert Ravix.Repo.get!(Ravix.Tracks.Track, track.id).sandbox_state == :ready
      else
        view |> form("#close-orphaned-private-form", confirm: project.name) |> render_submit()
        render_async(view)
        assert Ravix.Repo.get!(Ravix.Tracks.Track, track.id).sandbox_state == :closing
        refute has_element?(view, "#close-orphaned-private-form")
        refute render(view) =~ track.title
        assert {:error, :not_found} = Ravix.Tracks.get(owner, track.id)
      end
    end
  end
end
