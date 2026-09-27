defmodule Ravix.ProjectCreationGateTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts.Inference
  alias Ravix.Fountain.{Error, FakeTransport}
  alias Ravix.Projects
  alias Ravix.Projects.Project
  alias Ravix.Tooling.Catalog
  alias RavixWeb.Tooling.MCP
  import Ravix.ToolingFixture

  @sets "/api/account/inference-credential-sets"

  setup do
    %{
      owner:
        insert_user(agent: :claude, credential_kind: :subscription, credential_set_id: "mine")
    }
  end

  defp fountain(script) do
    client = FakeTransport.client(script)
    stub(Ravix.Fountain, :client, fn -> client end)
    client
  end

  defp catalog(runtimes \\ ["claude", "codex"]) do
    {%{method: "GET", path: "/api/catalog"},
     {200, [], %{data: %{runtimes: runtimes, models: %{}}}}}
  end

  defp held(providers, grant \\ nil) do
    {%{method: "GET", path: @sets},
     {200, [],
      %{
        data: [
          %{id: "other", providers: ["openai_api_key"], chatgpt_grant_id: "other-grant"},
          %{id: "mine", providers: providers, chatgpt_grant_id: grant}
        ]
      }}}
  end

  defp writes do
    [
      {%{method: "POST", path: "/api/environments"}, {201, [], %{data: %{id: "env"}}}},
      {%{method: "POST", path: "/api/vaults"}, {201, [], %{data: %{id: "vault"}}}},
      {%{method: "POST", path: "/api/agents"}, {201, [], %{data: %{id: "agent"}}}}
    ]
  end

  defp no_records(client) do
    assert Enum.all?(FakeTransport.calls(client), &(&1.method == "GET"))
    assert Repo.aggregate(Project, :count) == 0
  end

  defp assert_runtime(client, id, runtime) do
    assert Repo.get!(Project, id).runtime == runtime
    agent = Enum.find(FakeTransport.calls(client), &(&1.path == "/api/agents"))
    assert agent.body["runtime"] == runtime
    assert agent.body["inference_credential_id"] == "mine"
    assert Enum.count(FakeTransport.calls(client), &(&1.path == "/api/catalog")) == 1
  end

  test "a Claude-only owner cannot provision Codex or spend another person's credential", %{
    owner: owner
  } do
    client = fountain([catalog(), held(["claude_code_oauth_token"])])

    assert {:error,
            {:conflict, "agent_not_connected", "Connect Codex before creating a project with it."}} =
             Projects.create(owner, %{name: "Scratch", runtime: "codex"})

    no_records(client)
  end

  test "the same Claude-only owner can create a Claude project", %{owner: owner} do
    client = fountain([catalog(), held(["claude_code_oauth_token"]) | writes()])
    assert {:ok, project} = Projects.create(owner, %{name: "Scratch", runtime: "claude"})
    assert_runtime(client, project.id, "claude")

    refute Enum.any?(
             PostHog.Test.all_captured(),
             &(&1.event == "project created non default agent")
           )
  end

  test "absence is agent-specific, including a person with no set" do
    owner = insert_user(agent: :claude)
    client = fountain([catalog()])

    assert {:error,
            {:conflict, "agent_not_connected",
             "Connect Claude Code before creating a project with it."}} =
             Projects.create(owner, %{name: "Scratch"})

    no_records(client)
  end

  test "a missing set does not fall back to the saved choice", %{owner: owner} do
    client = fountain([catalog(), {%{method: "GET", path: @sets}, {200, [], %{data: []}}}])

    assert {:error, {:conflict, "agent_not_connected", _}} =
             Projects.create(owner, %{name: "Scratch"})

    no_records(client)
  end

  test "a credential lookup outage is a retryable provider error, not missing credentials", %{
    owner: owner
  } do
    client =
      fountain([catalog(), {%{method: "GET", path: @sets}, {503, [], %{error: "unavailable"}}}])

    assert {:error, %Error{status: 503} = error} = Projects.create(owner, %{name: "Scratch"})
    assert RavixWeb.Error.from(error).status in [502, 503, 504]
    no_records(client)
  end

  test "creation bypasses a warm cache after the credential was removed", %{owner: owner} do
    client = fountain([held(["openai_api_key"]), catalog(), held(["claude_code_oauth_token"])])
    assert Inference.usable?(owner, "codex") == {:ok, true}

    assert {:error, {:conflict, "agent_not_connected", _}} =
             Projects.create(owner, %{name: "Scratch", runtime: "codex"})

    no_records(client)
    assert Enum.count(FakeTransport.calls(client), &(&1.path == @sets)) == 2
  end

  test "an input runtime wins over the owner's default", %{owner: owner} do
    client = fountain([catalog(), held([], "codex-grant") | writes()])
    assert {:ok, project} = Projects.create(owner, %{name: "Scratch", runtime: "codex"})
    assert_runtime(client, project.id, "codex")
    assert Repo.get!(Ravix.Accounts.User, owner.id).agent == :claude

    assert [%{properties: properties}] =
             Enum.filter(
               PostHog.Test.all_captured(),
               &(&1.event == "project created non default agent")
             )

    assert properties["ravix.agent"] == "codex"
    assert properties["ravix.default_agent"] == "claude"
  end

  test "without a saved choice the checked and provisioned runtime is the catalog default" do
    owner = insert_user(credential_set_id: "mine")
    client = fountain([catalog(["codex"]), held(["openai_api_key"]) | writes()])
    assert {:ok, project} = Projects.create(owner, %{name: "Scratch"})
    assert_runtime(client, project.id, "codex")
  end

  test "MCP advertises an optional bounded runtime and its default" do
    tool = Catalog.find("create_project")

    assert tool.inputSchema["properties"]["runtime"] == %{
             "type" => "string",
             "enum" => ["claude", "codex"]
           }

    refute "runtime" in tool.inputSchema["required"]
    assert tool.description =~ "defaults to your account agent"
    assert tool.description =~ "agent_not_connected"
  end

  for runtime <- ["claude", "codex"] do
    test "MCP accepts explicit #{runtime} through the shared creation path", %{owner: owner} do
      runtime = unquote(runtime)

      client =
        fountain([catalog(), held(["claude_code_oauth_token", "openai_api_key"]) | writes()])

      {principal, _, _} = principal(owner)

      assert {:ok, %{isError: false, structuredContent: project}} =
               mcp_create(principal, %{"runtime" => runtime})

      assert_runtime(client, project.id, runtime)
    end
  end

  test "MCP reports the same tagged missing-credential error", %{owner: owner} do
    client = fountain([catalog(), held(["claude_code_oauth_token"])])
    {principal, _, _} = principal(owner)

    assert {:ok,
            %{
              isError: true,
              structuredContent: %{error: %{code: "agent_not_connected", message: message}}
            }} =
             mcp_create(principal, %{"runtime" => "codex"})

    assert message == "Connect Codex before creating a project with it."
    no_records(client)
  end

  test "MCP rejects invalid runtimes without touching Fountain", %{owner: owner} do
    client = fountain([])
    {principal, _, _} = principal(owner)

    for runtime <- ["claude-code", "gemini", "", 123, nil] do
      assert {:ok, %{isError: true, structuredContent: %{error: %{code: "invalid_arguments"}}}} =
               mcp_create(principal, %{"runtime" => runtime})
    end

    assert FakeTransport.calls(client) == []
    no_records(client)
  end

  test "MCP omitted runtime defaults to the owner's agent, not the catalog default" do
    owner = insert_user(agent: :codex, credential_set_id: "mine", credential_kind: :api_key)
    client = fountain([catalog(), held(["openai_api_key"]) | writes()])
    {principal, _, _} = principal(owner)
    assert {:ok, %{isError: false, structuredContent: project}} = mcp_create(principal, %{})
    assert_runtime(client, project.id, "codex")
  end

  defp mcp_create(principal, args) do
    MCP.call(principal, %{
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "create_project",
        "arguments" => Map.merge(%{"name" => "Scratch", "request_id" => "create"}, args)
      }
    })
  end
end
