defmodule Ravix.ProjectsTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Fountain.{Client, FakeTransport}
  alias Ravix.Fountain.Shapes
  alias Ravix.GitHubFake, as: GH
  alias Ravix.Hub.Event
  alias Ravix.Projects
  alias Ravix.Projects.{Machine, MachineState, Project, Settings}
  alias Ravix.Projects.Machine.{Harness, Rebuild}
  alias Ravix.PromptQueue.Item
  alias Ravix.QueryCount
  alias Ravix.Tracks

  # As Fountain serves it: a JSON object, string keys. A fixture that answered
  # atoms would be a shape no Fountain sends (see `Ravix.Fountain.Shapes`).
  @catalog %{"runtimes" => ["codex"], "models" => %{"codex" => ["openai/test-model"]}}
  @clone "GITHUB_TOKEN"

  # ── fixtures ──────────────────────────────────────────────────────────

  defp fountain(expectations \\ []) do
    client = FakeTransport.client(expectations)
    stub(Ravix.Fountain, :client, fn -> client end)
    client
  end

  defp no_fountain do
    stub(Ravix.Fountain, :client, fn ->
      Client.new("https://fountain.test", nil)
    end)
  end

  defp github(routes \\ []) do
    app = GH.app()
    stub(Ravix.Config, :github, fn -> app end)
    GH.install(routes)
    app
  end

  defp no_github, do: stub(Ravix.Config, :github, fn -> nil end)

  defp quiet_peers do
    stub(Ravix.MachineCache, :conversations, fn _client, _project, _opts -> {:ok, []} end)
    stub(Ravix.Tracks, :close_all_for_rebuild, fn _project, _reason -> :ok end)
    stub(Ravix.Previews.Lifecycle, :retire_project, fn _id -> :ok end)
    stub(Ravix.MachineCache, :forget_project, fn _id -> :ok end)
  end

  defp person(login, token \\ nil) do
    insert_user(login: login, token_enc: token && Ravix.Crypto.encrypt(token))
  end

  defp blank_project(owner, attrs \\ []) do
    insert_project(
      Keyword.merge(
        [
          user: owner,
          id: "p",
          name: "Project",
          repo_full_name: nil,
          installation_id: nil,
          default_branch: nil,
          agent_id: "a",
          environment_id: "e",
          vault_id: "v",
          runtime: "claude",
          model: "anthropic/claude-opus-5"
        ],
        attrs
      )
    )
  end

  defp repositories_route(installation_id, repos) do
    {"GET", "/user/installations/#{installation_id}/repositories",
     fn conn ->
       ["Bearer " <> token] = Plug.Conn.get_req_header(conn, "authorization")
       send(self(), {:repositories_as, token})
       Req.Test.json(conn, %{repositories: repos})
     end}
  end

  defp repo(full_name, opts \\ []) do
    [owner, name] = String.split(full_name, "/")

    %{
      full_name: full_name,
      name: name,
      owner: %{login: owner},
      private: Keyword.get(opts, :private, true),
      default_branch: Keyword.get(opts, :default_branch, "main"),
      pushed_at: "2026-09-01T00:00:00Z"
    }
  end

  defp requests(client), do: client |> FakeTransport.calls() |> Enum.map(&{&1.method, &1.path})

  defp body_of(client, method, path) do
    client
    |> FakeTransport.calls()
    |> Enum.find(&(&1.method == method and &1.path == path))
    |> Map.get(:body)
  end

  # ── pick_runtime (projects.test.ts) ───────────────────────────────────

  describe "pick_runtime/1" do
    # Every catalog here goes through `Shapes.catalog/1`, from the string keys
    # Fountain sends, rather than being written as the atom-keyed map the
    # deleted `field/2` used to accept.
    defp catalog(runtimes, models),
      do: Shapes.catalog(%{"runtimes" => runtimes, "models" => models})

    test "the default is provider-prefixed, the way Fountain writes them" do
      assert %{model: model} = Projects.pick_runtime(Shapes.Catalog.empty())
      assert model =~ ~r{^[a-z0-9_-]+/[a-z0-9._-]+$}
    end

    test "the catalog wins over the default when it offers the same model" do
      catalog =
        catalog(
          ["claude", "codex"],
          %{"claude" => ["anthropic/claude-opus-5", "anthropic/claude-sonnet-5"]}
        )

      assert Projects.pick_runtime(catalog) == %Harness{
               runtime: "claude",
               model: "anthropic/claude-opus-5"
             }
    end

    test "a Fountain without our preferred model still yields a usable one" do
      no_opus = catalog(["claude"], %{"claude" => ["anthropic/claude-sonnet-5"]})
      assert Projects.pick_runtime(no_opus).model == "anthropic/claude-sonnet-5"

      other_opus = catalog(["claude"], %{"claude" => ["vendor/opus-9"]})
      assert Projects.pick_runtime(other_opus).model == "vendor/opus-9"
    end

    test "a Fountain without our preferred runtime falls to its first" do
      no_claude = catalog(["codex"], %{"codex" => ["openai/gpt-5"]})
      assert Projects.pick_runtime(no_claude) == %Harness{runtime: "codex", model: "openai/gpt-5"}
    end

    test "an empty catalog is not a crash" do
      assert Projects.pick_runtime(Shapes.Catalog.empty()).runtime == "claude"
    end

    test "a runtime the catalog lists with no models falls to that runtime's default model" do
      # It used to fall to the one default there was, which handed a Codex agent
      # an Anthropic model: a project that builds and then fails its first turn.
      assert Projects.pick_runtime(catalog(["codex"], %{})) ==
               %Harness{runtime: "codex", model: "openai/gpt-6-astra"}
    end

    test "the agent the owner chose wins over the default when this Fountain runs it" do
      both =
        catalog(["claude", "codex"], %{
          "claude" => ["anthropic/claude-opus-5"],
          "codex" => ["openai/gpt-6-astra", "openai/gpt-5.5"]
        })

      assert Projects.pick_runtime(both, "codex") ==
               %Harness{runtime: "codex", model: "openai/gpt-6-astra"}

      assert Projects.pick_runtime(both, nil).runtime == "claude"
    end

    test "a catalog that could not be read does not overrule the owner's choice" do
      assert Projects.pick_runtime(Shapes.Catalog.empty(), "codex") ==
               %Harness{runtime: "codex", model: "openai/gpt-6-astra"}
    end
  end

  describe "Shapes.catalog/1" do
    test "an answer that is not an object is an empty catalog, not a crash" do
      assert Shapes.catalog("nope") == Shapes.Catalog.empty()
      assert Shapes.catalog(nil) == Shapes.Catalog.empty()
      assert Shapes.catalog(%{}) == Shapes.Catalog.empty()
    end

    test "values that are not strings are dropped rather than carried" do
      catalog =
        Shapes.catalog(%{
          "runtimes" => ["claude", 7, nil],
          "models" => %{"claude" => ["anthropic/claude-opus-5", %{}], "codex" => "not a list"}
        })

      assert catalog.runtimes == ["claude"]
      assert Shapes.Catalog.models_for(catalog, "claude") == ["anthropic/claude-opus-5"]
      assert Shapes.Catalog.models_for(catalog, "codex") == []
    end

    test "models_for/2 answers [] for a runtime the catalog does not list" do
      assert Shapes.Catalog.models_for(Shapes.Catalog.empty(), "claude") == []
    end
  end

  # ── the system prompt ─────────────────────────────────────────────────

  describe "compose_system/1" do
    test "the worktree rule first, the person's instructions after" do
      project = %Project{
        name: "Ravix",
        repo_full_name: "acme/ravix",
        default_branch: "main",
        instructions: "  Always run mix test.  "
      }

      system = Projects.compose_system(project)

      assert String.starts_with?(
               system,
               ~s(You are the coding agent on the Ravix machine for the project "Ravix".)
             )

      assert system =~ "/workspace/ravix is the shared clone"
      assert system =~ "The trunk is `main`."

      assert String.ends_with?(
               system,
               "## This project's own instructions\n\nAlways run mix test."
             )
    end

    test "blank instructions add nothing" do
      project = %Project{
        name: "Blank",
        repo_full_name: nil,
        default_branch: nil,
        instructions: "   "
      }

      system = Projects.compose_system(project)
      refute system =~ "own instructions"
      refute system =~ "shared clone"
      assert String.ends_with?(system, "back verbatim.")
    end
  end

  # ── access and shape ──────────────────────────────────────────────────

  describe "access_of/2 and present/4" do
    test "owner, whole project, one track, or nothing, widest first" do
      owner = person("owner")
      project = insert_project(user: owner)
      member = person("member")
      insert_project_member(project, member)
      guest = person("guest")
      track = insert_track(project: project)
      insert_track_member(track, guest)
      both = person("both")
      insert_project_member(project, both)
      insert_track_member(track, both)

      assert Projects.access_of(owner.id, project) == :owner
      assert Projects.access_of(member.id, project) == :project
      assert Projects.access_of(guest.id, project) == :tracks
      assert Projects.access_of(both.id, project) == :project
      assert Projects.access_of(person("stranger").id, project) == nil
    end

    test "the rail, the project page and the sidebar agree on how each person gets in" do
      # These three used to resolve access separately -- `Projects.list/1`,
      # `Projects.get/2` and `Tracks.list/2` each with a copy of the same
      # three questions -- and the copies had drifted in how they asked the
      # third. One answer now, and this is the assertion that the three
      # surfaces a person sees it on cannot disagree.
      quiet_peers()
      no_fountain()
      owner = person("owner")
      project = insert_project(user: owner, name: "shared")
      mine = insert_track(project: project, title: "theirs")
      other = insert_track(project: project, title: "not theirs")
      member = person("member")
      insert_project_member(project, member)
      guest = person("guest")
      insert_track_member(mine, guest)
      stranger = person("stranger")

      for {user, access, role, titles} <- [
            {owner, :owner, :owner, ["theirs", "not theirs"]},
            {member, :project, :member, ["theirs", "not theirs"]},
            {guest, :tracks, :member, ["theirs"]}
          ] do
        assert [%{id: id, access: ^access, role: ^role}] = Projects.list(user)
        assert id == project.id
        assert {:ok, %{access: ^access, role: ^role} = view} = Projects.get(user, project.id)
        assert view.name == "shared"
        assert view.display_name == if(role == :owner, do: "shared", else: "owner / shared")
        assert hd(Projects.list(user)).display_name == view.display_name
        assert {:ok, tracks} = Tracks.list(user, project.id)
        assert Enum.map(tracks, & &1.title) == titles
        assert Enum.all?(tracks, &(&1.role == role and &1.owner_login == "owner"))
      end

      assert Projects.list(stranger) == []
      assert Projects.get(stranger, project.id) == {:error, :not_found}
      assert Tracks.list(stranger, project.id) == {:error, :not_found}
      _ = other
    end

    test "the Project map, with the mount path and the two role questions" do
      owner = person("owner")
      project = insert_project(user: owner, repo_full_name: "acme/widgets", repo_private: true)

      map = Projects.present(project, :tracks, Machine.none(), owner)

      assert map.id == project.id
      assert map.repo == "acme/widgets"
      assert map.repo_path == "/workspace/widgets"
      assert map.repo_private == true
      assert map.machine == %MachineState{sandbox_id: nil, status: :none, sprite_name: nil}
      assert map.owner_login == "owner"
      assert map.role == :member
      assert map.access == :tracks
      assert map.rev == 1

      assert %{role: :owner, access: :owner, owner_login: "owner"} =
               Projects.present(project, :owner, Machine.none())

      # An owner with no account to name leaves the bare name, not " / name".
      orphan = Projects.present(project, :project, Machine.none(), nil)
      assert orphan.owner_login == ""
      assert orphan.display_name == project.name
    end
  end

  # ── list and get ──────────────────────────────────────────────────────

  describe "list/1" do
    test "own projects first, then the ones somebody let you into, each with its machine" do
      quiet_peers()
      fountain()
      me = person("me")
      mine = insert_project(user: me, name: "mine")
      other = person("other")
      whole = insert_project(user: other, name: "whole")
      insert_project_member(whole, me)
      partial = insert_project(user: other, name: "partial")
      insert_track_member(insert_track(project: partial), me)
      # Two tracks on one project is still one project in the rail.
      insert_track_member(insert_track(project: partial), me)
      archived = insert_project(user: other, name: "archived", archived_at: DateTime.utc_now())
      insert_project_member(archived, me)
      _unrelated = insert_project(user: other)

      # Through the real boundary: a stub that answered map literals would be
      # claiming a shape `Ravix.Fountain` does not build.
      conversations = &Enum.map(&1, fn raw -> Shapes.conversation(raw) end)

      stub(Ravix.MachineCache, :conversations, fn
        _client, %Project{id: id}, [] when id == mine.id ->
          {:ok,
           conversations.([
             %{
               "id" => "c1",
               "sandbox_id" => "sb-old",
               "status" => "idle",
               "inserted_at" => "2026-01-01"
             },
             %{
               "id" => "c2",
               "sandbox_id" => nil,
               "status" => "running",
               "inserted_at" => "2026-03-01"
             },
             %{
               "id" => "c3",
               "sandbox_id" => "sb-1",
               "status" => "running",
               "inserted_at" => "2026-02-01"
             }
           ])}

        _client, %Project{id: id}, [] when id == whole.id ->
          {:ok,
           conversations.([
             %{
               "id" => "c4",
               "sandbox_id" => "sb-2",
               "status" => "terminated",
               "inserted_at" => "x"
             }
           ])}

        _client, %Project{id: id}, [] when id == partial.id ->
          {:error, %Ravix.Fountain.Error{status: 500}}
      end)

      assert [first, second, third] = Projects.list(me)
      assert %{name: "mine", access: :owner, role: :owner, owner_login: "me"} = first
      assert first.machine == %MachineState{sandbox_id: "sb-1", status: :ready, sprite_name: nil}
      assert %{name: "whole", access: :project, role: :member, owner_login: "other"} = second

      assert second.machine ==
               %MachineState{sandbox_id: "sb-2", status: :suspended, sprite_name: nil}

      assert %{name: "partial", access: :tracks, role: :member} = third
      assert third.machine.status == :none
    end

    test "the rail costs the same whether a person helps on one track or across a team" do
      no_fountain()
      me = person("me")
      insert_project(user: me, name: "mine")
      other = person("other")
      whole = insert_project(user: other, name: "whole")
      insert_project_member(whole, me)
      partial = insert_project(user: other, name: "partial")
      insert_track_member(insert_track(project: partial), me)

      assert [%{name: "mine"}, %{name: "whole"}, %{name: "partial"}] = Projects.list(me)
      small = QueryCount.queries(fn -> Projects.list(me) end)

      # Two more whole projects, and four more shared tracks across three
      # projects, two of them under owners the rail has not seen before.
      third = person("third")

      for name <- ["whole 2", "whole 3"],
          do: insert_project_member(insert_project(user: third, name: name), me)

      insert_track_member(insert_track(project: partial), me)
      partial_2 = insert_project(user: other, name: "partial 2")
      insert_track_member(insert_track(project: partial_2), me)
      insert_track_member(insert_track(project: partial_2), me)
      partial_3 = insert_project(user: person("fourth"), name: "partial 3")
      insert_track_member(insert_track(project: partial_3), me)

      {listed, queries} = QueryCount.count(fn -> Projects.list(me) end)

      assert Enum.map(listed, & &1.name) ==
               ["mine", "whole", "whole 2", "whole 3", "partial", "partial 2", "partial 3"]

      assert Enum.map(listed, & &1.access) == [
               :owner,
               :project,
               :project,
               :project,
               :tracks,
               :tracks,
               :tracks
             ]

      assert Enum.map(listed, & &1.owner_login) == ~w(me other third third other other fourth)

      # Was one project read per shared track, then two or three more per
      # guest project for its membership and its owner: nine queries for the
      # small rail and twenty-three for this one. Five now, however long it is.
      assert length(queries) == small
      assert length(queries) == 5
      assert Enum.count(queries, &(&1 == "projects")) == 2
      assert Enum.count(queries, &(&1 == "project_members")) == 1
      assert Enum.count(queries, &(&1 == "track_members")) == 1
      assert Enum.count(queries, &(&1 == "users")) == 1
    end

    test "with no Fountain there are no machines, and no calls" do
      no_fountain()
      me = person("me")
      insert_project(user: me)
      reject(&Ravix.MachineCache.conversations/3)

      assert [%{machine: %{status: :none}}] = Projects.list(me)
    end
  end

  describe "get/2" do
    setup do
      quiet_peers()
      fountain()
      :ok
    end

    test "a member gets the same shape, marked with how they got here" do
      owner = person("owner")
      project = insert_project(user: owner)
      member = person("member")
      insert_project_member(project, member)

      assert {:ok, %{access: :project, role: :member, owner_login: "owner"}} =
               Projects.get(member, project.id)

      assert {:ok, %{access: :owner}} = Projects.get(owner, project.id)
    end

    test "a stranger, or an archived project, is not found" do
      project = insert_project()
      assert {:error, :not_found} = Projects.get(person("stranger"), project.id)

      gone = insert_project(archived_at: DateTime.utc_now())
      owner = Ravix.Accounts.Store.get_user(gone.user_id)
      assert {:error, :not_found} = Projects.get(owner, gone.id)
      assert {:error, :not_found} = Projects.get(owner, "nope")
    end
  end

  # ── create ────────────────────────────────────────────────────────────

  describe "create/2" do
    test "without Fountain there are no machines" do
      no_fountain()
      assert {:error, {:unconfigured, :fountain}} = Projects.create(person("me"), %{name: "x"})
    end

    test "blank projects reject installation credentials before creating upstream records" do
      fountain()
      github()
      guest = person("guest", "guest-token")

      assert {:error, {:unprocessable, "no_repo", _}} =
               Projects.create(guest, %{name: "Blank", installation_id: 99_999})

      assert GH.requests() == []
    end

    test "a blank project is an environment, a vault and an agent, no token" do
      client =
        fountain([
          {%{method: "POST", path: "/api/environments"}, {201, [], %{data: %{id: "new-env"}}}},
          {%{method: "POST", path: "/api/vaults"}, {201, [], %{data: %{id: "new-vault"}}}},
          {%{method: "GET", path: "/api/catalog"}, {200, [], %{data: @catalog}}},
          {%{method: "POST", path: "/api/agents"}, {201, [], %{data: %{id: "new-agent"}}}}
        ])

      github()
      me = person("me", "me-token")

      assert {:ok, project} = Projects.create(me, %{"name" => "  Blank  "})
      assert %{name: "Blank", repo: nil, repo_path: nil, role: :owner, access: :owner} = project
      assert project.machine.status == :none
      assert %{runtime: "codex", model: "openai/test-model", rev: 1, owner_login: "me"} = project

      assert %Project{
               agent_id: "new-agent",
               environment_id: "new-env",
               vault_id: "new-vault",
               runtime: "codex",
               model: "openai/test-model",
               installation_id: nil,
               instructions: ""
             } = Repo.get!(Project, project.id)

      assert body_of(client, "POST", "/api/environments") == %{
               "name" => "Ravix · Blank",
               "repositories" => [],
               "packages" => %{},
               "setup_script" => ""
             }

      agent = body_of(client, "POST", "/api/agents")
      assert agent["runtime"] == "codex"
      assert agent["model"] == "openai/test-model"
      assert agent["sandbox_mode"] == "persistent"
      assert agent["environment_id"] == "new-env"
      assert agent["vault_id"] == "new-vault"
      assert agent["metadata"] == %{"ravix" => %{"project" => project.id}}
      assert agent["description"] == "The agent on this Ravix project."
      assert agent["system"] =~ ~s(for the project "Blank")
      assert GH.requests() == []
    end

    test "a warm repository picker cannot authorize creation after access is removed" do
      app = github([repositories_route(1, [repo("owner/repo")])])
      me = person("owner", "owner-token")
      client = fountain()
      assert {:ok, [_]} = Ravix.GitHub.repositories(app, "owner-token", 1)
      GH.install([repositories_route(1, [])])

      assert {:error, {:not_found, "repo_not_found", _}} =
               Projects.create(me, %{repo: "owner/repo", installation_id: 1})

      assert GH.request_count("repositories") == 2
      assert requests(client) == []
    end

    test "repository access is checked before minting the installation token" do
      app = github()
      GH.install([GH.token_route(app), repositories_route(1, [repo("owner/repo")])])
      me = person("owner", "owner-token")
      fountain()

      assert {:error, {:not_found, "repo_not_found", _}} =
               Projects.create(me, %{repo: "stranger/private", installation_id: 1})

      assert_received {:repositories_as, "owner-token"}
      assert GH.request_count("access_tokens") == 0

      client =
        fountain([
          {%{method: "POST", path: "/api/environments"}, {201, [], %{data: %{id: "new-env"}}}},
          {%{method: "POST", path: "/api/vaults"}, {201, [], %{data: %{id: "new-vault"}}}},
          {%{
             method: "POST",
             path: "/api/vaults/new-vault/secrets",
             body: %{key: @clone, value: "token-1"}
           }, {201, [], %{data: %{key: @clone}}}},
          {%{method: "GET", path: "/api/catalog"}, {200, [], %{data: @catalog}}},
          {%{method: "POST", path: "/api/agents"}, {201, [], %{data: %{id: "new-agent"}}}}
        ])

      assert {:ok, project} = Projects.create(me, %{repo: "Owner/Repo", installation_id: "1"})

      assert %{name: "repo", repo: "owner/repo", repo_path: "/workspace/repo", repo_private: true} =
               project

      assert project.default_branch == "main"
      assert GH.request_count("access_tokens") == 1

      assert %Project{repo_full_name: "owner/repo", installation_id: 1, repo_private: true} =
               Repo.get!(Project, project.id)

      assert body_of(client, "POST", "/api/environments")["repositories"] == [
               %{
                 "url" => "https://github.com/owner/repo.git",
                 "mount_path" => "/workspace/repo",
                 "secret_key" => @clone
               }
             ]

      agent = body_of(client, "POST", "/api/agents")
      assert agent["description"] == "The agent working on owner/repo."
      assert agent["system"] =~ "/workspace/repo is the shared clone"

      assert requests(client) == [
               {"POST", "/api/environments"},
               {"POST", "/api/vaults"},
               {"POST", "/api/vaults/new-vault/secrets"},
               {"GET", "/api/catalog"},
               {"POST", "/api/agents"}
             ]
    end

    test "a repository needs an installation, and a project needs a name" do
      fountain()
      github()
      me = person("me", "me-token")

      assert {:error, {:unprocessable, "no_installation", _}} =
               Projects.create(me, %{repo: "owner/repo"})

      assert {:error, {:unprocessable, "no_name", _}} = Projects.create(me, %{name: "   "})
    end

    test "a person whose GitHub token is gone is sent to sign in again" do
      fountain()
      github()

      assert {:error, {:reauthenticate, _}} =
               Projects.create(person("me"), %{repo: "owner/repo", installation_id: 1})
    end

    test "a Fountain without vaults still builds, and the agent has none" do
      client =
        fountain([
          {%{method: "POST", path: "/api/environments"}, {201, [], %{data: %{id: "new-env"}}}},
          {%{method: "POST", path: "/api/vaults"}, {501, [], %{error: "not_implemented"}}},
          {%{method: "GET", path: "/api/catalog"}, {500, [], "boom"}},
          {%{method: "POST", path: "/api/agents"}, {201, [], %{data: %{id: "new-agent"}}}}
        ])

      app = github()
      GH.install([GH.token_route(app), repositories_route(1, [repo("owner/repo")])])
      me = person("me", "me-token")

      assert {:ok, project} = Projects.create(me, %{repo: "owner/repo", installation_id: 1})

      assert %Project{vault_id: nil, runtime: "claude", model: "anthropic/claude-opus-5"} =
               Repo.get!(Project, project.id)

      refute Map.has_key?(body_of(client, "POST", "/api/agents"), "vault_id")
      assert GH.request_count("access_tokens") == 0
    end

    test "the machine is built with the owner's agent and pointed at the owner's credential set" do
      client =
        fountain([
          {%{method: "POST", path: "/api/environments"}, {201, [], %{data: %{id: "new-env"}}}},
          {%{method: "POST", path: "/api/vaults"}, {201, [], %{data: %{id: "new-vault"}}}},
          {%{method: "GET", path: "/api/catalog"},
           {200, [],
            %{
              data: %{
                runtimes: ["claude", "codex"],
                models: %{
                  "claude" => ["anthropic/claude-opus-5"],
                  "codex" => ["openai/gpt-6-astra"]
                }
              }
            }}},
          {%{method: "POST", path: "/api/agents"}, {201, [], %{data: %{id: "new-agent"}}}}
        ])

      no_github()
      me = insert_user(agent: :codex, credential_kind: :api_key, credential_set_id: "set-me")

      assert {:ok, project} = Projects.create(me, %{name: "Scratch"})

      agent = body_of(client, "POST", "/api/agents")
      assert agent["runtime"] == "codex"
      assert agent["model"] == "openai/gpt-6-astra"
      assert agent["inference_credential_id"] == "set-me"
      # Closed, so no launch can name a set that is not the owner's.
      assert agent["allowed_inference_credential_ids"] == []

      assert %Project{runtime: "codex", credential_set_id: "set-me"} =
               Repo.get!(Project, project.id)
    end

    test "somebody who connected nothing gets the agent this app always built" do
      client =
        fountain([
          {%{method: "POST", path: "/api/environments"}, {201, [], %{data: %{id: "new-env"}}}},
          {%{method: "POST", path: "/api/vaults"}, {201, [], %{data: %{id: "new-vault"}}}},
          {%{method: "GET", path: "/api/catalog"}, {500, [], "boom"}},
          {%{method: "POST", path: "/api/agents"}, {201, [], %{data: %{id: "new-agent"}}}}
        ])

      no_github()
      assert {:ok, project} = Projects.create(person("me"), %{name: "Scratch"})

      agent = body_of(client, "POST", "/api/agents")
      refute Map.has_key?(agent, "inference_credential_id")
      refute Map.has_key?(agent, "allowed_inference_credential_ids")
      assert %Project{runtime: "claude", credential_set_id: nil} = Repo.get!(Project, project.id)
    end

    test "an agent this Fountain does not run is refused, and nothing is left behind" do
      client =
        fountain([
          {%{method: "POST", path: "/api/environments"}, {201, [], %{data: %{id: "new-env"}}}},
          {%{method: "POST", path: "/api/vaults"}, {201, [], %{data: %{id: "new-vault"}}}},
          {%{method: "GET", path: "/api/catalog"},
           {200, [], %{data: %{runtimes: ["claude"], models: %{}}}}},
          {%{method: "DELETE", path: "/api/vaults/new-vault"}, {204, [], nil}},
          {%{method: "DELETE", path: "/api/environments/new-env"}, {204, [], nil}}
        ])

      no_github()
      me = insert_user(agent: :codex, credential_kind: :api_key, credential_set_id: "set-me")

      assert {:error, {:conflict, "agent_unavailable", _}} =
               Projects.create(me, %{name: "Scratch"})

      refute {"POST", "/api/agents"} in requests(client)
      assert Repo.aggregate(Project, :count) == 0
    end

    test "a failure unwinds what went in, in reverse, and reports the original error" do
      client =
        fountain([
          {%{method: "POST", path: "/api/environments"}, {201, [], %{data: %{id: "new-env"}}}},
          {%{method: "POST", path: "/api/vaults"}, {201, [], %{data: %{id: "new-vault"}}}},
          {%{method: "GET", path: "/api/catalog"}, {200, [], %{data: @catalog}}},
          {%{method: "POST", path: "/api/agents"},
           {422, [], %{error: "validation_failed", message: "model is invalid"}}},
          {%{method: "DELETE", path: "/api/vaults/new-vault"}, {204, [], nil}},
          {%{method: "DELETE", path: "/api/environments/new-env"}, {500, [], "no"}}
        ])

      github()
      me = person("me", "me-token")

      assert {:error, %Ravix.Fountain.Error{status: 422, message: "model is invalid"}} =
               Projects.create(me, %{name: "Doomed"})

      assert Repo.all(Project) == []
      assert List.last(requests(client)) == {"DELETE", "/api/environments/new-env"}
    end

    test "a mint failure before the first build unwinds the vault and the environment" do
      client =
        fountain([
          {%{method: "POST", path: "/api/environments"}, {201, [], %{data: %{id: "new-env"}}}},
          {%{method: "POST", path: "/api/vaults"}, {201, [], %{data: %{id: "new-vault"}}}},
          {%{method: "DELETE", path: "/api/vaults/new-vault"}, {204, [], nil}},
          {%{method: "DELETE", path: "/api/environments/new-env"}, {204, [], nil}}
        ])

      github([
        {"POST", ~r{/access_tokens$}, {503, %{message: "mint unavailable"}}},
        repositories_route(1, [repo("owner/repo")])
      ])

      me = person("me", "me-token")

      assert {:error, %Ravix.GitHub.Error{status: 503}} =
               Projects.create(me, %{repo: "owner/repo", installation_id: 1})

      assert {"DELETE", "/api/vaults/new-vault"} in requests(client)
      assert Repo.all(Project) == []
    end
  end

  # ── prepare_machine ───────────────────────────────────────────────────

  describe "prepare_machine/2 adopting the owner's credential set" do
    test "a project made before its owner connected is moved onto their set, once" do
      client =
        fountain([{%{method: "PUT", path: "/api/agents/a"}, {200, [], %{data: %{id: "a"}}}}])

      owner = insert_user(agent: :claude, credential_kind: :subscription, credential_set_id: "s1")
      project = blank_project(owner)

      assert :ok = Projects.prepare_machine(project, client)

      assert body_of(client, "PUT", "/api/agents/a") == %{
               "inference_credential_id" => "s1",
               "allowed_inference_credential_ids" => []
             }

      # The row remembers, so the next wake is a comparison and not a call: the
      # script above holds one PUT and a second would fail this test.
      adopted = Repo.get!(Project, project.id)
      assert adopted.credential_set_id == "s1"
      assert :ok = Projects.prepare_machine(adopted, client)
    end

    test "it is the owner's set whoever wakes the machine" do
      client =
        fountain([{%{method: "PUT", path: "/api/agents/a"}, {200, [], %{data: %{id: "a"}}}}])

      owner = insert_user(agent: :claude, credential_kind: :api_key, credential_set_id: "owners")
      _guest = insert_user(agent: :codex, credential_kind: :api_key, credential_set_id: "guests")

      assert :ok = Projects.prepare_machine(blank_project(owner), client)
      assert body_of(client, "PUT", "/api/agents/a")["inference_credential_id"] == "owners"
    end

    test "an owner who connected nothing leaves the agent where it was" do
      client = fountain()
      assert :ok = Projects.prepare_machine(blank_project(person("owner")), client)
      assert requests(client) == []
    end

    test "a Fountain that will not move the agent stops the wake and records nothing" do
      client =
        fountain([{%{method: "PUT", path: "/api/agents/a"}, {500, [], %{error: "nope"}}}])

      owner = insert_user(agent: :claude, credential_kind: :subscription, credential_set_id: "s1")
      project = blank_project(owner)

      assert {:error, %Ravix.Fountain.Error{status: 500}} =
               Projects.prepare_machine(project, client)

      assert Repo.get!(Project, project.id).credential_set_id == nil
    end
  end

  describe "prepare_machine/2 and refresh_clone_token/2" do
    test "legacy blank projects do not refresh an unverified installation" do
      client = fountain()
      github([GH.token_route(GH.app())])
      project = blank_project(person("owner"), installation_id: 99)

      assert :ok = Projects.prepare_machine(project, client)
      assert GH.requests() == []
    end

    test "propagates mint and vault failures instead of starting with stale credentials" do
      app = github()
      project = blank_project(person("owner"), repo_full_name: "owner/repo", installation_id: 1)

      GH.install([{"POST", ~r{/access_tokens$}, {503, %{message: "mint unavailable"}}}])
      client = fountain()

      assert {:error, %Ravix.GitHub.Error{message: "mint unavailable"}} =
               Projects.prepare_machine(project, client)

      assert requests(client) == []

      GH.install([GH.token_route(app)])

      client =
        fountain([
          {%{method: "POST", path: "/api/vaults/v/secrets"},
           {503, [], %{error: "unavailable", message: "vault unavailable"}}},
          {%{
             method: "POST",
             path: "/api/vaults/v/secrets",
             body: %{key: @clone, value: "token-2"}
           }, {201, [], %{data: %{key: @clone}}}}
        ])

      assert {:error, %Ravix.Fountain.Error{status: 503}} =
               Projects.prepare_machine(project, client)

      assert :ok = Projects.prepare_machine(project, client)
    end

    test "without the GitHub App there is nothing to mint" do
      no_github()
      client = fountain()
      project = blank_project(person("owner"), repo_full_name: "owner/repo", installation_id: 1)
      assert {:error, {:unconfigured, :github}} = Projects.prepare_machine(project, client)
    end

    test "the one-argument forms use this deployment's client, or say there is none" do
      project = blank_project(person("owner"), repo_full_name: "owner/repo", installation_id: 1)
      no_fountain()
      assert {:error, {:unconfigured, :fountain}} = Projects.prepare_machine(project)

      assert {:error, {:unconfigured, :fountain}} =
               Projects.refresh_clone_token(%{vault_id: "v", installation_id: 1})

      app = github()
      GH.install([GH.token_route(app)])

      fountain([
        {%{method: "POST", path: "/api/vaults/v/secrets"}, {201, [], %{data: %{key: @clone}}}}
      ])

      assert :ok = Projects.prepare_machine(project)
    end
  end

  # ── settings ──────────────────────────────────────────────────────────

  describe "settings/2" do
    test "the environment, the key names without the clone token, and the catalog" do
      owner = person("owner")
      project = blank_project(owner)

      fountain([
        {%{method: "GET", path: "/api/environments/e"},
         {200, [], %{data: %{id: "e", setup_script: "apt update", packages: %{apt: ["ripgrep"]}}}}},
        {%{method: "GET", path: "/api/environments/e/secrets"},
         {200, [], %{data: [%{key: "API_KEY"}]}}},
        {%{method: "GET", path: "/api/vaults/v/secrets"},
         {200, [], %{data: [%{key: @clone}, %{key: "OPENAI_KEY"}]}}},
        {%{method: "GET", path: "/api/catalog"}, {200, [], %{data: @catalog}}}
      ])

      assert {:ok, settings} = Projects.settings(owner, project.id)

      assert settings == %Ravix.Projects.Settings{
               runtime: "claude",
               catalog: %Shapes.Catalog{
                 runtimes: ["codex"],
                 models: %{"codex" => ["openai/test-model"]}
               },
               name: "Project",
               setup_script: "apt update",
               packages: %{"apt" => ["ripgrep"]},
               env_keys: ["API_KEY"],
               vault_keys: ["OPENAI_KEY"],
               model: "anthropic/claude-opus-5",
               instructions: ""
             }
    end

    test "catalog and key outages degrade; an environment outage does not" do
      owner = person("owner")
      project = blank_project(owner, vault_id: nil)

      fountain([
        {%{method: "GET", path: "/api/environments/e"}, {200, [], %{data: %{id: "e"}}}},
        {%{method: "GET", path: "/api/environments/e/secrets"}, {500, [], "down"}},
        {%{method: "GET", path: "/api/catalog"}, {500, [], "down"}}
      ])

      empty = Shapes.Catalog.empty()

      assert {:ok,
              %{catalog: ^empty, env_keys: [], vault_keys: [], setup_script: "", packages: %{}}} =
               Projects.settings(owner, project.id)

      fountain([
        {%{method: "GET", path: "/api/environments/e"}, {404, [], %{error: "not_found"}}}
      ])

      assert {:error, %Ravix.Fountain.Error{status: 404}} = Projects.settings(owner, project.id)
    end

    test "members and strangers are refused as not found" do
      fountain()
      project = blank_project(person("owner"))
      member = person("member")
      insert_project_member(project, member)

      assert {:error, :not_found} = Projects.settings(member, project.id)
      assert {:error, :not_found} = Projects.update_settings(member, project.id, %{name: "x"})
      assert {:error, :not_found} = Projects.rebuild(member, project.id)
      assert {:error, :not_found} = Projects.destroy(member, project.id)
    end
  end

  describe "update_settings/3" do
    setup do
      owner = person("owner")
      project = blank_project(owner)
      tracks = for id <- ["t", "other"], do: insert_track(project: project, id: id, slug: id)
      Ravix.Hub.subscribe(project.id)
      %{owner: owner, project: project, tracks: tracks}
    end

    test "settings switch harness in place for future tracks", %{owner: owner, project: project} do
      client =
        fountain([
          {%{method: "GET", path: "/api/catalog"}, {200, [], %{data: @catalog}}},
          {%{
             method: "PUT",
             path: "/api/agents/a",
             body: %{runtime: "codex", model: "openai/test-model"}
           }, {200, [], %{data: %{id: "a"}}}}
        ])

      assert {:ok, %{rev: 2}} =
               Projects.update_settings(owner, project.id, %{
                 runtime: "codex",
                 model: "openai/test-model"
               })

      assert %Project{
               runtime: "codex",
               model: "openai/test-model",
               agent_id: "a",
               environment_id: "e",
               rev: 2
             } =
               Repo.get!(Project, project.id)

      assert [%{rev: 1}, %{rev: 1}] = Projects.Store.open_tracks(project.id)
      assert_received {:hub, %Event{name: :settings}}
      assert length(requests(client)) == 2
    end

    test "invalid harness/model pairs are rejected before any settings change", %{
      owner: owner,
      project: project
    } do
      # The code says which box. A runtime the catalog does not know makes
      # every model wrong, so that is the one to report; past that the
      # runtime is fine and the model is not.
      for {attrs, code} <- [
            # A runtime the catalog offers, with the model left on this
            # project's own, which that runtime does not have.
            {%{runtime: "codex"}, "invalid_model"},
            # Only the model given, so the runtime stays this project's
            # `claude` --- which this catalog does not offer at all. The
            # harness is the box to fix, and saying "choose one of this
            # harness's models" about a harness that is gone would send
            # somebody looking in the wrong list.
            {%{model: "invented"}, "invalid_runtime"},
            {%{runtime: "unknown", model: "openai/test-model"}, "invalid_runtime"},
            # Clearing the harness box and saving. An empty string is a
            # value the browser can actually send, so `cast_attrs/1` keeps
            # it and the catalog refuses it, rather than reading it as "say
            # nothing about the harness" and keeping the old one silently.
            {%{runtime: ""}, "invalid_runtime"}
          ] do
        client =
          fountain([{%{method: "GET", path: "/api/catalog"}, {200, [], %{data: @catalog}}}])

        assert {:error, {:unprocessable, ^code, _}} =
                 Projects.update_settings(owner, project.id, Map.put(attrs, :name, "Changed"))

        assert requests(client) == [{"GET", "/api/catalog"}]
      end

      assert %Project{name: "Project", runtime: "claude", rev: 1} = Repo.get!(Project, project.id)
      refute_received {:hub, _}
    end

    test "a field nobody mentioned is a field nobody changes", %{owner: owner, project: project} do
      client = fountain([])

      # Absence is the instruction: this is what lets the settings form, the
      # secret form and the preview defaults form all arrive at `update/3`
      # and each change only its own half. `nil` says the same thing --- no
      # browser sends one, so it can only come from inside Ravix, and
      # "leave it alone" is the reading that makes the boundary explicit.
      assert {:ok, %{rev: 1}} = Projects.update_settings(owner, project.id, %{})
      assert {:ok, %{rev: 1}} = Projects.update_settings(owner, project.id, %{runtime: nil})

      assert requests(client) == []
      assert %Project{name: "Project", runtime: "claude", rev: 1} = Repo.get!(Project, project.id)
    end

    test "upstream failure preserves the saved harness and model", %{
      owner: owner,
      project: project
    } do
      fountain([
        {%{method: "GET", path: "/api/catalog"}, {200, [], %{data: @catalog}}},
        {%{method: "PUT", path: "/api/agents/a"}, {:error, :econnrefused}}
      ])

      assert {:error, %Ravix.Fountain.Error{} = error} =
               Projects.update_settings(owner, project.id, %{
                 runtime: "codex",
                 model: "openai/test-model"
               })

      assert Ravix.Fountain.Error.unreachable?(error)

      assert %Project{runtime: "claude", model: "anthropic/claude-opus-5", rev: 1} =
               Repo.get!(Project, project.id)
    end

    test "catalog outages allow unrelated edits and preserve current selection", %{
      owner: owner,
      project: project
    } do
      fountain([])

      assert {:ok, %{rev: 1}} =
               Projects.update_settings(owner, project.id, %{
                 name: "  Renamed  ",
                 runtime: "claude",
                 model: "anthropic/claude-opus-5"
               })

      assert %Project{name: "Renamed", rev: 1} = Repo.get!(Project, project.id)
      assert_received {:hub, %Event{name: :settings}}
    end

    test "a blank name is not a rename", %{owner: owner, project: project} do
      fountain([])
      assert {:ok, %{rev: 1}} = Projects.update_settings(owner, project.id, %{name: "   "})
      assert Repo.get!(Project, project.id).name == "Project"
    end

    test "instructions go after the rule on the agent, and bump the revision", %{
      owner: owner,
      project: project
    } do
      client =
        fountain([{%{method: "PUT", path: "/api/agents/a"}, {200, [], %{data: %{id: "a"}}}}])

      assert {:ok, %{rev: 2}} =
               Projects.update_settings(owner, project.id, %{"instructions" => "Use tabs."})

      assert Repo.get!(Project, project.id).instructions == "Use tabs."
      system = body_of(client, "PUT", "/api/agents/a")["system"]
      assert String.ends_with?(system, "## This project's own instructions\n\nUse tabs.")
      assert system =~ "## The one rule"
    end

    test "the setup script and packages patch the environment without a bump", %{
      owner: owner,
      project: project
    } do
      client =
        fountain([
          {%{method: "PUT", path: "/api/environments/e"}, {200, [], %{data: %{id: "e"}}}}
        ])

      assert {:ok, %{rev: 1}} =
               Projects.update_settings(owner, project.id, %{
                 setup_script: "npm ci",
                 packages: %{
                   "apt" => ["ripgrep", " ripgrep ", "", 3],
                   "npm" => "typescript",
                   "" => ["x"]
                 }
               })

      assert body_of(client, "PUT", "/api/environments/e") == %{
               "setup_script" => "npm ci",
               "packages" => %{"apt" => ["ripgrep"], "" => ["x"]}
             }

      assert Settings.normalize_packages(["ripgrep"]) == %{}
      assert Settings.normalize_packages(nil) == %{}
    end

    test "secrets: named, not reserved, and only in a store the project has", %{
      owner: owner,
      project: project
    } do
      client =
        fountain([
          {%{
             method: "POST",
             path: "/api/vaults/v/secrets",
             body: %{key: "OPENAI_KEY", value: "sk"}
           }, {201, [], %{data: %{key: "OPENAI_KEY"}}}},
          {%{method: "DELETE", path: "/api/environments/e/secrets/API_KEY"}, {204, [], nil}}
        ])

      assert {:error, {:unprocessable, "bad_key", _}} =
               Projects.update_settings(owner, project.id, %{
                 secret: %{store: "vault", key: "9lives", value: "x"}
               })

      assert {:error, {:unprocessable, "reserved_key", _}} =
               Projects.update_settings(owner, project.id, %{
                 secret: %{store: "vault", key: @clone, value: "x"}
               })

      assert {:ok, %{rev: 2}} =
               Projects.update_settings(owner, project.id, %{
                 secret: %{"store" => "vault", "key" => " OPENAI_KEY ", "value" => "sk"}
               })

      assert {:ok, %{rev: 3}} =
               Projects.update_settings(owner, project.id, %{
                 secret: %{store: "env", key: "API_KEY", value: ""}
               })

      assert length(requests(client)) == 2

      vaultless = blank_project(owner, id: "p2", vault_id: nil)

      assert {:error, {:conflict, "no_vault", _}} =
               Projects.update_settings(owner, vaultless.id, %{
                 secret: %{store: "vault", key: "K", value: "v"}
               })
    end

    test "without Fountain nothing can be saved", %{owner: owner, project: project} do
      no_fountain()

      assert {:error, {:unconfigured, :fountain}} =
               Projects.update_settings(owner, project.id, %{name: "x"})
    end
  end

  # ── rebuild and destroy ───────────────────────────────────────────────

  describe "rebuild/2" do
    setup do
      owner = person("owner")
      project = blank_project(owner)
      track = insert_track(project: project, id: "t", slug: "t", conversation_id: "c-t")
      prompt = insert_prompt(track: track, user: owner)
      Ravix.Hub.subscribe(project.id)
      %{owner: owner, project: project, track: track, prompt: prompt}
    end

    test "retires the agent, keeps the environment and vault, closes every track", ctx do
      %{owner: owner, project: project, prompt: prompt} = ctx
      test_pid = self()

      stub(Ravix.Previews.Lifecycle, :retire_project, fn id -> send(test_pid, {:retired, id}) end)
      stub(Ravix.MachineCache, :forget_project, fn id -> send(test_pid, {:forgot, id}) end)

      stub(Ravix.Tracks, :close_all_for_rebuild, fn %Project{id: id}, reason ->
        send(test_pid, {:closed_all, id, reason})
        :ok
      end)

      client =
        fountain([
          {%{method: "GET", path: "/api/conversations", query: %{agent_id: "a"}},
           {200, [],
            %{
              data: [
                %{id: "c-live", status: "running", channel_id: "ravix:p:t@r1"},
                %{id: "c-stuck", status: "idle", channel_id: nil},
                %{id: "c-old", status: "terminated", channel_id: nil}
              ]
            }}},
          {%{method: "POST", path: "/api/conversations/c-live/terminate"},
           {200, [], %{data: %{ok: true}}}},
          {%{method: "POST", path: "/api/conversations/c-stuck/terminate"},
           {409, [], %{error: "conversation_busy", message: "still busy"}}},
          {%{method: "DELETE", path: "/api/agents/a"}, {204, [], nil}},
          {%{method: "GET", path: "/api/catalog"}, {200, [], %{data: @catalog}}},
          {%{method: "POST", path: "/api/agents"}, {201, [], %{data: %{id: "new-agent"}}}}
        ])

      assert {:ok,
              %Rebuild{
                removed: ["track", "agent"],
                failed: [%Rebuild.Failure{what: "track c-stuck", why: "still busy"}]
              }} =
               Projects.rebuild(owner, project.id)

      assert %Project{
               agent_id: "new-agent",
               environment_id: "e",
               vault_id: "v",
               runtime: "claude"
             } =
               Repo.get!(Project, project.id)

      # The project's own harness, not the catalog's: the same settings.
      agent = body_of(client, "POST", "/api/agents")

      assert %{"runtime" => "claude", "model" => "anthropic/claude-opus-5", "vault_id" => "v"} =
               agent

      assert agent["environment_id"] == "e"
      assert agent["metadata"] == %{"ravix" => %{"project" => "p"}}

      assert Repo.get_by!(Item, id: prompt.id).status == :cancelled
      assert_received {:retired, "p"}
      assert_received {:forgot, "p"}
      assert_received {:closed_all, "p", :rebuild}
      assert_received {:hub, %Event{name: :tracks, project_id: "p"}}
    end

    test "the replacement agent is built on the owner's credential set as it is today", ctx do
      quiet_peers()
      %{owner: owner, project: project} = ctx

      # Connected after the project was made, so the row still says nothing.
      {:ok, owner} =
        Ravix.Accounts.save_setup(owner, %{
          agent: :claude,
          credential_kind: :subscription,
          credential_set_id: "owners-set"
        })

      client =
        fountain([
          {%{method: "GET", path: "/api/conversations", query: %{agent_id: "a"}},
           {200, [], %{data: []}}},
          {%{method: "DELETE", path: "/api/agents/a"}, {204, [], nil}},
          {%{method: "GET", path: "/api/catalog"}, {200, [], %{data: @catalog}}},
          {%{method: "POST", path: "/api/agents"}, {201, [], %{data: %{id: "new-agent"}}}}
        ])

      assert {:ok, %Rebuild{}} = Projects.rebuild(owner, project.id)

      agent = body_of(client, "POST", "/api/agents")
      assert agent["inference_credential_id"] == "owners-set"
      assert agent["allowed_inference_credential_ids"] == []

      assert %Project{agent_id: "new-agent", credential_set_id: "owners-set"} =
               Repo.get!(Project, project.id)
    end

    test "the catalog fills in a project with no harness of its own", %{
      owner: owner,
      project: project
    } do
      quiet_peers()
      Repo.update_all(Project, set: [runtime: "", model: ""])

      client =
        fountain([
          {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}},
          {%{method: "DELETE", path: "/api/agents/a"}, {204, [], nil}},
          {%{method: "GET", path: "/api/catalog"}, {200, [], %{data: @catalog}}},
          {%{method: "POST", path: "/api/agents"}, {201, [], %{data: %{id: "new-agent"}}}}
        ])

      assert {:ok, %Rebuild{removed: ["agent"], failed: []}} = Projects.rebuild(owner, project.id)

      assert %{"runtime" => "codex", "model" => "openai/test-model"} =
               body_of(client, "POST", "/api/agents")
    end

    test "a machine that cannot be found, or an agent that will not go, is an error", ctx do
      %{owner: owner, project: project} = ctx
      quiet_peers()
      reject(&Ravix.Tracks.close_all_for_rebuild/2)

      fountain([{%{method: "GET", path: "/api/conversations"}, {:error, :timeout}}])
      assert {:error, %Ravix.Fountain.Error{status: 0}} = Projects.rebuild(owner, project.id)

      fountain([
        {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}},
        {%{method: "DELETE", path: "/api/agents/a"}, {500, [], %{error: "nope"}}}
      ])

      assert {:error, %Ravix.Fountain.Error{status: 500}} = Projects.rebuild(owner, project.id)
      assert Repo.get!(Project, project.id).agent_id == "a"
      refute_received {:hub, %Event{name: :tracks}}
    end

    test "a rebuild that lost its agent and then failed can still be retried", ctx do
      %{owner: owner, project: project} = ctx
      quiet_peers()

      # The old agent goes; its replacement does not arrive.
      fountain([
        {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}},
        {%{method: "DELETE", path: "/api/agents/a"}, {204, [], %{}}},
        {%{method: "GET", path: "/api/catalog"}, {200, [], %{runtimes: [], models: []}}},
        {%{method: "POST", path: "/api/agents"}, {500, [], %{error: "no capacity"}}}
      ])

      assert {:error, %Ravix.Fountain.Error{status: 500}} = Projects.rebuild(owner, project.id)
      assert Repo.get!(Project, project.id).agent_id == "a"

      # `agent_id` still names an agent Fountain no longer has, so the retry
      # meets a 404 on the delete. Treating that as "already gone" is what
      # keeps the project rebuildable rather than leaving destroy as the only
      # way out of a half-finished rebuild.
      fountain([
        {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}},
        {%{method: "DELETE", path: "/api/agents/a"}, {404, [], %{error: "not_found"}}},
        {%{method: "GET", path: "/api/catalog"}, {200, [], %{runtimes: [], models: []}}},
        {%{method: "POST", path: "/api/agents"}, {200, [], %{id: "b"}}}
      ])

      assert {:ok, _report} = Projects.rebuild(owner, project.id)
      assert Repo.get!(Project, project.id).agent_id == "b"
    end
  end

  describe "destroy/2" do
    test "the machine, its settings and its secrets; the row archived", _ctx do
      quiet_peers()
      owner = person("owner")
      project = blank_project(owner)
      track = insert_track(project: project, id: "t", slug: "t")
      prompt = insert_prompt(track: track, user: owner)
      Ravix.Hub.subscribe(project.id)

      client =
        fountain([
          {%{method: "GET", path: "/api/conversations"},
           {200, [], %{data: [%{id: "c-live", status: "idle"}, %{id: "c-old", status: "failed"}]}}},
          {%{method: "POST", path: "/api/conversations/c-live/terminate"}, {500, [], "meh"}},
          {%{method: "DELETE", path: "/api/agents/a"}, {204, [], nil}},
          {%{method: "DELETE", path: "/api/vaults/v"}, {404, [], %{error: "not_found"}}},
          {%{method: "DELETE", path: "/api/environments/e"}, {204, [], nil}}
        ])

      assert :ok = Projects.destroy(owner, project.id)

      assert %Project{archived_at: %DateTime{}} = Repo.get!(Project, project.id)
      assert Repo.get_by!(Item, id: prompt.id).status == :cancelled
      assert_received {:hub, %Event{name: :tracks, project_id: "p"}}
      assert List.last(requests(client)) == {"DELETE", "/api/environments/e"}
      assert {:error, :not_found} = Projects.get(owner, project.id)
      assert Projects.list(owner) == []
    end

    test "a conversation list that will not load does not stop the delete" do
      quiet_peers()
      owner = person("owner")
      project = blank_project(owner, vault_id: nil)

      fountain([
        {%{method: "GET", path: "/api/conversations"}, {:error, :timeout}},
        {%{method: "DELETE", path: "/api/agents/a"}, {204, [], nil}},
        {%{method: "DELETE", path: "/api/environments/e"}, {204, [], nil}}
      ])

      assert :ok = Projects.destroy(owner, project.id)
      assert Repo.get!(Project, project.id).archived_at
    end
  end

  # ── GitHub, for the picker ────────────────────────────────────────────

  describe "repos/2" do
    test "the person's installations and the repositories of the chosen one" do
      github([
        {"GET", "/user/installations",
         %{
           installations: [
             %{id: 1, account: %{login: "acme", avatar_url: nil}},
             %{id: 2, account: %{login: "me"}}
           ]
         }},
        repositories_route(2, [repo("me/dots", private: false)]),
        repositories_route(1, [repo("acme/widgets")])
      ])

      me = person("me", "me-token")

      assert {:ok, %{selected: 2, repos: [%{full_name: "me/dots", installation_id: 2}]} = out} =
               Projects.repos(me, 2)

      assert [%{id: 1, account: "acme"}, %{id: 2, account: "me"}] = out.installations
      assert_received {:repositories_as, "me-token"}

      # An installation the person cannot see falls back to the first.
      assert {:ok, %{selected: 1, repos: [%{full_name: "acme/widgets"}]}} = Projects.repos(me, 99)
    end

    test "no installation at all is the state before access is granted, not an error" do
      github([{"GET", "/user/installations", %{installations: []}}])

      assert {:ok, %{installations: [], selected: nil, repos: []}} =
               Projects.repos(person("me", "t"))
    end

    test "an expired sign-in asks for a new one; other failures pass through" do
      github([{"GET", "/user/installations", {401, %{message: "Bad credentials"}}}])
      assert {:error, {:reauthenticate, message}} = Projects.repos(person("me", "t"))
      assert message =~ "Sign in again"

      github([{"GET", "/user/installations", {403, %{message: "Resource not accessible"}}}])
      assert {:error, %Ravix.GitHub.Error{status: 403}} = Projects.repos(person("me", "t"))

      github()
      assert {:error, {:reauthenticate, _}} = Projects.repos(person("me"))

      no_github()
      assert {:error, {:unconfigured, :github}} = Projects.repos(person("me", "t"))
    end
  end

  describe "refs/3" do
    setup do
      app = github()
      owner = person("owner")

      project =
        insert_project(
          user: owner,
          repo_full_name: "acme/widgets",
          installation_id: 7,
          default_branch: "trunk"
        )

      member = person("member")
      insert_project_member(project, member)
      %{app: app, owner: owner, project: project, member: member}
    end

    test "branches, pulls and issues, read as the installation", %{
      app: app,
      project: project,
      member: member
    } do
      GH.install([
        GH.token_route(app),
        {"GET", "/repos/acme/widgets/branches",
         [%{name: "feature", commit: %{sha: "f"}}, %{name: "trunk", commit: %{sha: "t"}}]},
        {"GET", "/repos/acme/widgets/pulls",
         [
           %{
             number: 3,
             title: "PR",
             user: %{login: "x"},
             head: %{ref: "h"},
             base: %{ref: "trunk"},
             draft: false,
             updated_at: "u",
             state: "open"
           }
         ]},
        {"GET", "/repos/acme/widgets/issues",
         [
           %{number: 4, title: "Issue", user: %{login: "y"}, labels: [], updated_at: "u"},
           %{number: 5, pull_request: %{}}
         ]}
      ])

      assert {:ok, [%{name: "trunk", is_default: true}, %{name: "feature", is_default: false}]} =
               Projects.refs(member, project.id, :branches)

      assert {:ok, [%{number: 3, head_ref: "h"}]} = Projects.refs(member, project.id, "pulls")
      assert {:ok, [%{number: 4}]} = Projects.refs(member, project.id, :issues)
      assert GH.request_count("access_tokens") == 1
    end

    test "a stranger is not found; a project without a repository has nothing to start from",
         ctx do
      %{owner: owner, project: project} = ctx
      assert {:error, :not_found} = Projects.refs(person("stranger"), project.id, :branches)

      blank = insert_project(user: owner, repo_full_name: nil, installation_id: nil)
      assert {:error, {:conflict, "no_repo", _}} = Projects.refs(owner, blank.id, :branches)

      no_github()
      assert {:error, {:unconfigured, :github}} = Projects.refs(owner, project.id, :branches)
    end
  end

  # ── the rows ──────────────────────────────────────────────────────────

  describe "the rows" do
    test "bump_rev returns the new revision; rebind moves the agent and what pays for it" do
      project = insert_project()
      assert Projects.Store.bump_rev(project.id) == 2
      assert Projects.Store.bump_rev(project.id) == 3
      assert Projects.Store.bump_rev("missing") == 1

      assert :ok = Projects.Store.rebind_agent(project.id, "agent-2", "set-2")
      assert :ok = Projects.Store.set_harness(project.id, "codex", "openai/x")
      assert :ok = Projects.Store.set_instructions(project.id, "hi")
      assert :ok = Projects.Store.rename(project.id, "new name")

      assert %Project{
               agent_id: "agent-2",
               credential_set_id: "set-2",
               runtime: "codex",
               model: "openai/x",
               instructions: "hi",
               name: "new name",
               rev: 3
             } =
               Projects.Store.get_project(project.id)

      assert Projects.Store.get_project(nil) == nil
    end

    test "projects_of lists live projects oldest first; archive cancels what was queued" do
      owner = person("owner")
      first = insert_project(user: owner)
      second = insert_project(user: owner)
      _gone = insert_project(user: owner, archived_at: DateTime.utc_now())
      track = insert_track(project: first)
      prompt = insert_prompt(track: track, user: owner)
      sent = insert_prompt(track: track, user: owner, status: "sent")

      assert Enum.map(Projects.Store.projects_of(owner.id), & &1.id) == [first.id, second.id]

      assert :ok = Projects.Store.archive(first.id)
      assert Repo.get_by!(Item, id: prompt.id).status == :cancelled
      assert Repo.get_by!(Item, id: sent.id).status == :sent
      assert Enum.map(Projects.Store.projects_of(owner.id), & &1.id) == [second.id]
    end

    test "create_project starts at revision 1 and refuses a row with no agent" do
      owner = person("owner")

      assert {:ok, %Project{rev: 1, created_at: %DateTime{}}} =
               Projects.Store.create_project(%{
                 id: "fresh",
                 user_id: owner.id,
                 name: "Fresh",
                 agent_id: "a",
                 environment_id: "e",
                 runtime: "claude",
                 model: "anthropic/claude-opus-5",
                 rev: 9
               })

      assert {:error, %Ecto.Changeset{}} =
               Projects.Store.create_project(%{id: "x", user_id: owner.id, name: "x"})
    end
  end
end
