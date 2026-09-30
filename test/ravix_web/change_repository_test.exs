defmodule RavixWeb.ChangeRepositoryTest do
  @moduledoc """
  RAV-76: the Danger zone's "Change repository". The context's own answers
  are `Ravix.ProjectsTest`'s; this is the page: the typed confirmation, what
  it says for each answer, and that nobody but a signed-in owner reaches it.
  """
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Projects
  alias Ravix.Projects.Machine.Rebuild
  alias Ravix.Repo

  setup :verify_on_exit!

  setup %{conn: conn} do
    stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude, :codex]} end)
    user = insert_user()
    project = insert_project(user: user, name: "Atlas", repo_full_name: "acme/atlas")
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    %{conn: conn, view: view, user: user, project: project}
  end

  test "suggests the repositories the App reads, and changes only on the typed name", ctx do
    danger(ctx, fn user, id ->
      assert {user.id, id} == {ctx.user.id, ctx.project.id}
      {:ok, ["acme/cabinet", "acme/ledger"]}
    end)

    assert has_element?(ctx.view, "#change-repository-current", "acme/atlas")
    assert has_element?(ctx.view, "#change-repository-choices option[value='acme/cabinet']")
    assert has_element?(ctx.view, "#change-repository-choices option[value='acme/ledger']")
    assert has_element?(ctx.view, "#change-repository-submit[disabled]")

    # The one call `expect/3` allows below is the typed-name one.
    submit(ctx.view, "acme/cabinet", "wrong")
    assert render(ctx.view) =~ "Type the project name to confirm."
    # What was typed stays for the second try.
    assert has_element?(ctx.view, "#change-repository-repo[value='acme/cabinet']")

    ctx.view
    |> form("#change-repository-form", repo: "acme/cabinet", confirm: "Atlas")
    |> render_change()

    refute has_element?(ctx.view, "#change-repository-submit[disabled]")

    expect(Projects, :change_repository, fn user, id, repo ->
      assert {user.id, id, repo} == {ctx.user.id, ctx.project.id, "acme/cabinet"}
      {:ok, %Rebuild{removed: ["track", "agent"], failed: []}}
    end)

    submit(ctx.view, " acme/cabinet ", "Atlas")
    html = settled(ctx.view)

    assert html =~
             "Atlas now uses acme/cabinet. Its tracks were closed and the machine is being rebuilt."

    assert has_element?(ctx.view, "#change-repository-repo[value='']")
    assert has_element?(ctx.view, "#change-repository-confirm[value='']")
  end

  test "a repository the App cannot read is refused, and the form keeps what was typed", ctx do
    danger(ctx)

    expect(Projects, :change_repository, fn _, _, "acme/secret" ->
      {:error,
       {:not_found, "repo_not_readable",
        "The Ravix GitHub App cannot read that repository. Install the App on it, or grant it that repository, and try again."}}
    end)

    submit(ctx.view, "acme/secret", "Atlas")
    html = settled(ctx.view)
    assert html =~ "The Ravix GitHub App cannot read that repository."
    refute html =~ "now uses"
    assert has_element?(ctx.view, "#change-repository-repo[value='acme/secret']")
  end

  test "a change whose rebuild failed says the repository changed and what is left", ctx do
    danger(ctx)

    expect(Projects, :change_repository, fn _, _, _ ->
      {:error, {:not_rebuilt, {:conflict, "machine_cleanup_pending", "Try again shortly."}}}
    end)

    submit(ctx.view, "acme/cabinet", "Atlas")

    assert settled(ctx.view) =~
             "Atlas now uses acme/cabinet, but the machine was not rebuilt: Try again shortly. Rebuild it from this page."
  end

  test "a failed rebuild still reports what it could not stop", ctx do
    danger(ctx)

    expect(Projects, :change_repository, fn _, _, _ ->
      {:ok,
       %Rebuild{
         removed: ["agent"],
         failed: [%Rebuild.Failure{what: "track c1", why: "still busy"}]
       }}
    end)

    submit(ctx.view, "acme/cabinet", "Atlas")
    assert settled(ctx.view) =~ "1 track would not stop first: still busy"
  end

  test "a second submit while the first is out starts nothing", ctx do
    danger(ctx)
    parent = self()

    expect(Projects, :change_repository, 1, fn _, _, _ ->
      send(parent, {:changing, self()})

      receive do
        :finish -> {:ok, %Rebuild{removed: ["agent"], failed: []}}
      after
        2_000 -> flunk("the change was never released")
      end
    end)

    submit(ctx.view, "acme/cabinet", "Atlas")
    assert_receive {:changing, changing}, 1000
    assert has_element?(ctx.view, "#change-repository-submit[disabled]")
    submit(ctx.view, "acme/cabinet", "Atlas")
    send(changing, :finish)
    assert settled(ctx.view) =~ "now uses acme/cabinet"
  end

  describe "who reaches it" do
    test "a revoked session cannot fill in the form", ctx do
      view = revoked(ctx)
      reject(&Projects.change_repository/3)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view
               |> form("#change-repository-form", repo: "acme/cabinet", confirm: "Atlas")
               |> render_change()
    end

    test "a revoked session cannot change the repository", ctx do
      view = revoked(ctx)
      reject(&Projects.change_repository/3)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view
               |> form("#change-repository-form", repo: "acme/cabinet", confirm: "Atlas")
               |> render_submit()

      assert Repo.get!(Ravix.Projects.Project, ctx.project.id).repo_full_name == "acme/atlas"
    end

    test "an owner who lost the project is refused before any write", ctx do
      danger(ctx)
      render_async(ctx.view, 1_000)
      reject(&Projects.change_repository/3)

      ctx.project
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
      |> Repo.update!()

      submit(ctx.view, "acme/cabinet", "Atlas")
      html = render(ctx.view)
      assert html =~ "No such thing here."
      refute html =~ "now uses"
    end

    test "another person's project draws no form and changes nothing", ctx do
      stranger = insert_user()
      reject(&Projects.change_repository/3)
      reject(&Projects.repository_choices/2)

      {:ok, view, _} = live(log_in_user(ctx.conn, stranger), "/")
      render_patch(view, "/p/#{ctx.project.id}/settings/danger")
      render_async(view)
      refute has_element?(view, "#change-repository-form")
      assert Repo.get!(Ravix.Projects.Project, ctx.project.id).repo_full_name == "acme/atlas"
    end
  end

  defp revoked(ctx) do
    {token, session} = insert_session(ctx.user)
    conn = Plug.Test.init_test_session(ctx.conn, session_token: token)
    {:ok, view, _} = live(conn, "/p/#{ctx.project.id}")
    danger(%{ctx | view: view})
    Repo.delete!(session)
    view
  end

  defp submit(view, repo, confirm) do
    view
    |> form("#change-repository-form", repo: repo, confirm: confirm)
    |> render_submit()
  end

  # The answer, and the flash it hands the page one message later.
  defp settled(view) do
    render_async(view, 1000)
    :sys.get_state(view.pid)
    render(view)
  end

  defp danger(ctx, choices \\ fn _, _ -> {:ok, []} end) do
    stub(Projects, :settings, fn _, _ ->
      {:ok,
       %{
         env_vars: %{},
         name: ctx.project.name,
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

    stub(Projects, :repository_choices, choices)
    render_patch(ctx.view, "/p/#{ctx.project.id}/settings/danger")
    render_async(ctx.view)
  end
end
