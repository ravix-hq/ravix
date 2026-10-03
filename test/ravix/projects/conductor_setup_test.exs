defmodule Ravix.Projects.ConductorSetupTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.GitHubFake, as: GH
  alias Ravix.Projects.ConductorSetup

  setup :verify_on_exit!

  setup do
    user = insert_user()

    project =
      insert_project(
        user: user,
        repo_full_name: "org/repo",
        installation_id: 8,
        default_branch: "feature/import"
      )

    app = GH.app()
    stub(Ravix.Config, :github, fn -> app end)
    %{user: user, project: project, app: app}
  end

  test "authenticated contents reads stay on project repository/default branch and decode bounded files",
       ctx do
    contents(ctx, %{
      ".conductor/settings.toml" => "[scripts]\nsetup = 'npm ci'\nrun = 'npm dev --port $PORT'",
      ".worktreeinclude" => ".env.local"
    })

    assert {:ok, report} = ConductorSetup.discover(ctx.user, ctx.project.id)
    assert report.repository == "org/repo"
    assert report.branch == "feature/import"
    assert report.setup.command == "npm ci"
    assert report.patterns == [".env.local"]
    assert length(GH.requests()) == 4
  end

  test "non-owner, project member and track-only share cannot discover repository setup", ctx do
    stranger = insert_user()
    member = insert_user()
    track_member = insert_user()
    insert_project_member(ctx.project, member)
    track = insert_track(project: ctx.project)
    insert_track_member(track, track_member)

    for user <- [stranger, member, track_member] do
      assert {:error, :not_found} = ConductorSetup.discover(user, ctx.project.id)
    end

    assert GH.requests() == []
  end

  test "missing files produce an empty report without mutations", ctx do
    contents(ctx, %{})

    assert {:ok, %{sources: [], runs: [], setup: nil}} =
             ConductorSetup.discover(ctx.user, ctx.project.id)
  end

  test "repository-less and unconfigured projects refuse predictably", ctx do
    project = insert_project(user: ctx.user, repo_full_name: nil)
    assert {:error, {:unprocessable, _, _}} = ConductorSetup.discover(ctx.user, project.id)
    stub(Ravix.Config, :github, fn -> nil end)
    assert {:error, {:unconfigured, :github}} = ConductorSetup.discover(ctx.user, ctx.project.id)
  end

  test "GitHub transport/permission errors are not mistaken for missing configuration", ctx do
    for status <- [401, 403, 500] do
      GH.install([
        GH.token_route(ctx.app),
        {"GET", ~r{/contents/}, {status, %{message: "blocked"}}}
      ])

      assert {:error, %Ravix.GitHub.Error{status: ^status}} =
               ConductorSetup.discover(ctx.user, ctx.project.id)
    end
  end

  test "oversized files, non-files and malformed base64 are refused", ctx do
    for answer <- [
          %{type: "file", encoding: "base64", size: 65_537, content: ""},
          %{type: "dir"},
          %{type: "symlink"},
          %{type: "file", encoding: "base64", size: 3, content: "???"},
          %{
            type: "file",
            encoding: "base64",
            size: 1,
            content: Base.encode64(String.duplicate("x", 65_537))
          },
          %{type: "file", encoding: "base64", size: 1, content: String.duplicate("x", 90_001)}
        ] do
      GH.install([GH.token_route(ctx.app), {"GET", ~r{/contents/}, answer}])
      assert {:error, {:unprocessable, _, _}} = ConductorSetup.discover(ctx.user, ctx.project.id)
    end
  end

  test "access is checked again after provider reads", ctx do
    contents(ctx, %{})
    expect(Ravix.Accounts.Access, :project_of, fn _, _ -> {:ok, ctx.project} end)
    expect(Ravix.Accounts.Access, :project_of, fn _, _ -> {:error, :not_found} end)
    assert {:error, :not_found} = ConductorSetup.discover(ctx.user, ctx.project.id)
  end

  test "repository changes during discovery cannot surface old candidates", ctx do
    contents(ctx, %{})
    expect(Ravix.Accounts.Access, :project_of, fn _, _ -> {:ok, ctx.project} end)

    expect(Ravix.Accounts.Access, :project_of, fn _, _ ->
      {:ok, %{ctx.project | repo_full_name: "org/new"}}
    end)

    assert {:error, {:conflict, "conductor_setup", _}} =
             ConductorSetup.discover(ctx.user, ctx.project.id)
  end

  defp contents(ctx, files) do
    GH.install([
      GH.token_route(ctx.app),
      {"GET", ~r{^/repos/org/repo/contents/},
       fn conn ->
         assert ["Bearer token-1"] = Plug.Conn.get_req_header(conn, "authorization")
         assert URI.decode_query(conn.query_string)["ref"] == "feature/import"
         path = String.replace_prefix(conn.request_path, "/repos/org/repo/contents/", "")

         case files[path] do
           nil ->
             conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{message: "Not Found"})

           text ->
             Req.Test.json(conn, %{
               type: "file",
               encoding: "base64",
               size: byte_size(text),
               content: Base.encode64(text) <> "\n"
             })
         end
       end}
    ])
  end
end
