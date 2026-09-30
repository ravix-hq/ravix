defmodule RavixWeb.ChangeRepositoryTest do
  @moduledoc """
  RAV-76: the Danger zone's "Change repository…" dialog. The context's own
  answers are `Ravix.ProjectsTest`'s; this is the page: the three steps
  (pick, review, typed name), what it says for each answer, and that nobody
  but a signed-in owner reaches it.
  """
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Projects
  alias Ravix.Projects.Machine.Rebuild
  alias Ravix.Repo
  alias Ravix.Tracks

  setup :verify_on_exit!

  @choices [%{repo: "acme/cabinet", private: false}, %{repo: "acme/ledger", private: true}]

  setup %{conn: conn} do
    stub(Ravix.Accounts.Inference, :usable_agents, fn _ -> {:ok, [:claude, :codex]} end)
    user = insert_user()
    project = insert_project(user: user, name: "Atlas", repo_full_name: "acme/atlas")
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    %{conn: conn, view: view, user: user, project: project}
  end

  test "the dialog offers what the App reads, says how many tracks close, and asks the name",
       ctx do
    danger(ctx)
    assert has_element?(ctx.view, "#change-repository-current", "acme/atlas")
    refute has_element?(ctx.view, "#change-repository-dialog")

    stub(Tracks, :list, fn user, id ->
      assert {user.id, id} == {ctx.user.id, ctx.project.id}
      {:ok, [%{sandbox_layout: :shared}, %{sandbox_layout: :shared}]}
    end)

    open(ctx.view, fn user, id ->
      assert {user.id, id} == {ctx.user.id, ctx.project.id}
      {:ok, @choices}
    end)

    assert has_element?(ctx.view, "#change-repository-list [data-repo='acme/cabinet']")
    assert has_element?(ctx.view, "#change-repository-list [data-repo='acme/ledger']", "Private")
    assert has_element?(ctx.view, "#change-repository-closing", "2 open tracks will close")

    assert render(ctx.view) =~
             "their branches stay on GitHub, and unpushed work on the machine is lost. Settings, secrets, environment variables, members and history are kept."

    # The list narrows as the picker's does.
    ctx.view |> form("#change-repository-query-form", q: "LED") |> render_change()
    refute has_element?(ctx.view, "#change-repository-list [data-repo='acme/cabinet']")
    ctx.view |> form("#change-repository-query-form", q: "") |> render_change()

    # Nothing picked: the typed name alone does not enable it.
    type(ctx.view, "Atlas")
    assert has_element?(ctx.view, "#change-repository-submit[disabled]")

    pick(ctx.view, "acme/cabinet")
    assert has_element?(ctx.view, "#change-repository-list [data-repo='acme/cabinet'].on")
    assert has_element?(ctx.view, "#change-repository-review", "rebuilt from acme/cabinet")
    refute has_element?(ctx.view, "#change-repository-submit[disabled]")

    # The one call `expect/3` allows is the typed-name one.
    submit(ctx.view, "wrong")
    assert render(ctx.view) =~ "Type the project name to confirm."
    assert has_element?(ctx.view, "#change-repository-dialog")

    expect(Projects, :change_repository, fn user, id, repo ->
      assert {user.id, id, repo} == {ctx.user.id, ctx.project.id, "acme/cabinet"}
      {:ok, %Rebuild{removed: ["track", "agent"], failed: []}}
    end)

    submit(ctx.view, "Atlas")
    html = settled(ctx.view)

    assert html =~
             "Atlas now uses acme/cabinet. Its tracks were closed and the machine is being rebuilt."

    refute has_element?(ctx.view, "#change-repository-dialog")
  end

  test "a repository the dialog did not offer cannot be picked or submitted", ctx do
    danger(ctx)
    open(ctx.view)
    reject(&Projects.change_repository/3)

    render_click(
      ctx.view |> element("#change-repository-list [data-repo='acme/cabinet']"),
      %{"repo" => "evil/elsewhere"}
    )

    refute has_element?(ctx.view, "#change-repository-list button.on")
    submit(ctx.view, "Atlas")
    refute render(ctx.view) =~ "now uses"
  end

  test "Cancel and Escape close the dialog and keep nothing", ctx do
    danger(ctx)
    open(ctx.view)
    pick(ctx.view, "acme/cabinet")
    ctx.view |> element("#change-repository-dialog button", "Cancel") |> render_click()
    refute has_element?(ctx.view, "#change-repository-dialog")

    open(ctx.view)
    refute has_element?(ctx.view, "#change-repository-list button.on")

    ctx.view
    |> element("#change-repository-dialog")
    |> render_keydown(%{"key" => "Escape"})

    refute has_element?(ctx.view, "#change-repository-dialog")
  end

  test "no repository to offer, or a count that cannot be read, still says what happens", ctx do
    danger(ctx)
    stub(Tracks, :list, fn _, _ -> {:error, {:unavailable, "later"}} end)
    open(ctx.view, fn _, _ -> {:ok, []} end)

    assert render(ctx.view) =~ "The Ravix GitHub App cannot read any other repository here."
    assert has_element?(ctx.view, "#change-repository-closing", "Every open track will close")
  end

  test "a repository the App cannot read is refused, and the dialog keeps what was chosen", ctx do
    danger(ctx)
    open(ctx.view)
    pick(ctx.view, "acme/ledger")

    expect(Projects, :change_repository, fn _, _, "acme/ledger" ->
      {:error,
       {:not_found, "repo_not_readable",
        "The Ravix GitHub App cannot read that repository. Install the App on it, or grant it that repository, and try again."}}
    end)

    submit(ctx.view, "Atlas")
    html = settled(ctx.view)
    assert html =~ "The Ravix GitHub App cannot read that repository."
    refute html =~ "now uses"
    assert has_element?(ctx.view, "#change-repository-list [data-repo='acme/ledger'].on")
  end

  test "another project already on it is refused with that project's name", ctx do
    danger(ctx)
    open(ctx.view)
    pick(ctx.view, "acme/cabinet")

    expect(Projects, :change_repository, fn _, _, _ ->
      {:error,
       {:conflict, "repository_taken",
        "This workspace already has a project for that repository: Cabinet."}}
    end)

    submit(ctx.view, "Atlas")
    assert settled(ctx.view) =~ "already has a project for that repository: Cabinet."
  end

  test "a change whose rebuild failed says the repository changed and what is left", ctx do
    danger(ctx)
    open(ctx.view)
    pick(ctx.view, "acme/cabinet")

    expect(Projects, :change_repository, fn _, _, _ ->
      {:error, {:not_rebuilt, {:conflict, "machine_cleanup_pending", "Try again shortly."}}}
    end)

    submit(ctx.view, "Atlas")

    assert settled(ctx.view) =~
             "Atlas now uses acme/cabinet, but the machine was not rebuilt: Try again shortly. Rebuild it from this page."
  end

  test "a rebuild that could not stop a track still says so", ctx do
    danger(ctx)
    open(ctx.view)
    pick(ctx.view, "acme/cabinet")

    expect(Projects, :change_repository, fn _, _, _ ->
      {:ok,
       %Rebuild{
         removed: ["agent"],
         failed: [%Rebuild.Failure{what: "track c1", why: "still busy"}]
       }}
    end)

    submit(ctx.view, "Atlas")
    assert settled(ctx.view) =~ "1 track would not stop first: still busy"
  end

  test "while a change is out, nothing else starts and the dialog stays", ctx do
    danger(ctx)
    open(ctx.view)
    pick(ctx.view, "acme/cabinet")
    parent = self()

    expect(Projects, :change_repository, 1, fn _, _, _ ->
      send(parent, {:changing, self()})

      receive do
        :finish -> {:ok, %Rebuild{removed: ["agent"], failed: []}}
      after
        2_000 -> flunk("the change was never released")
      end
    end)

    submit(ctx.view, "Atlas")
    assert_receive {:changing, changing}, 1000
    assert has_element?(ctx.view, "#change-repository-submit[disabled]")
    submit(ctx.view, "Atlas")
    # Cancel is disabled; Escape is refused while the change is out.
    ctx.view |> element("#change-repository-dialog") |> render_keydown(%{"key" => "Escape"})
    assert has_element?(ctx.view, "#change-repository-dialog")
    send(changing, :finish)
    assert settled(ctx.view) =~ "now uses acme/cabinet"
  end

  describe "who reaches it" do
    test "a revoked session cannot open the dialog", ctx do
      view = revoked(ctx)
      reject(&Projects.repository_choices/2)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> element("#open-change-repository") |> render_click()
    end

    test "a revoked session cannot change the repository from an open dialog", ctx do
      {token, session} = insert_session(ctx.user)
      conn = Plug.Test.init_test_session(ctx.conn, session_token: token)
      {:ok, view, _} = live(conn, "/p/#{ctx.project.id}")
      danger(%{ctx | view: view})
      open(view)
      pick(view, "acme/cabinet")
      Repo.delete!(session)
      reject(&Projects.change_repository/3)

      assert {:error, {:redirect, %{to: "/login"}}} =
               view
               |> form("#change-repository-form", confirm: "Atlas")
               |> render_submit()

      assert Repo.get!(Ravix.Projects.Project, ctx.project.id).repo_full_name == "acme/atlas"
    end

    test "an owner who lost the project is refused before any write", ctx do
      danger(ctx)
      open(ctx.view)
      pick(ctx.view, "acme/cabinet")
      reject(&Projects.change_repository/3)

      ctx.project
      |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
      |> Repo.update!()

      submit(ctx.view, "Atlas")
      html = render(ctx.view)
      assert html =~ "No such thing here."
      refute html =~ "now uses"
    end

    for role <- [:admin, :write, :read] do
      @role role
      test "a direct #{role} member of the project gets no Danger zone", ctx do
        member = insert_user()
        insert_project_member(ctx.project, member, role: @role)
        reject(&Projects.change_repository/3)
        reject(&Projects.repository_choices/2)

        {:ok, view, _} = live(log_in_user(ctx.conn, member), "/p/#{ctx.project.id}")
        render_patch(view, "/p/#{ctx.project.id}/settings/danger")
        render_async(view, 1_000)
        refute has_element?(view, "#open-change-repository")
        refute has_element?(view, "#change-repository-dialog")
      end
    end

    test "another person's project id draws nothing and changes nothing", ctx do
      stranger = insert_user()
      reject(&Projects.change_repository/3)
      reject(&Projects.repository_choices/2)

      {:ok, view, _} = live(log_in_user(ctx.conn, stranger), "/")
      render_patch(view, "/p/#{ctx.project.id}/settings/danger")
      render_async(view, 1_000)
      refute has_element?(view, "#open-change-repository")
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

  defp open(view, choices \\ fn _, _ -> {:ok, @choices} end) do
    stub(Projects, :repository_choices, choices)
    view |> element("#open-change-repository") |> render_click()
    render_async(view, 1_000)
  end

  defp pick(view, repo),
    do: view |> element("#change-repository-list [data-repo='#{repo}']") |> render_click()

  defp type(view, name),
    do: view |> form("#change-repository-form", confirm: name) |> render_change()

  defp submit(view, name),
    do: view |> form("#change-repository-form", confirm: name) |> render_submit()

  # The answer, and the flash it hands the page one message later.
  defp settled(view) do
    render_async(view, 1000)
    :sys.get_state(view.pid)
    render(view)
  end

  defp danger(ctx) do
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

    stub(Tracks, :list, fn _, _ -> {:ok, []} end)
    render_patch(ctx.view, "/p/#{ctx.project.id}/settings/danger")
    render_async(ctx.view)
  end
end
