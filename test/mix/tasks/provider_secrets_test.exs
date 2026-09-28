defmodule Mix.Tasks.Ravix.ProviderSecretsTest do
  @moduledoc """
  The creator-billing activation check, as the runbook runs it: the Mix task
  and its release twin. The inventory itself is `Ravix.CreatorBillingTest`'s;
  here it is what gets printed, that it is names only, and the exit status.

  Not async: `Mix.shell/1` is global.
  """
  use Ravix.DataCase, async: false
  use Mimic

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ravix.ProviderSecrets, as: Task
  alias Ravix.Fountain.FakeTransport

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    project = insert_project(vault_id: nil)
    %{project: project}
  end

  defp fountain(project, env_vars, secrets, allowed \\ []) do
    env = project.environment_id

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/environments/#{env}"},
         {200, [], %{data: %{id: env, env_vars: env_vars}}}},
        {%{method: "GET", path: "/api/environments/#{env}/secrets"},
         {200, [], %{data: Enum.map(secrets, &%{key: &1})}}},
        agent(project, allowed)
      ])

    stub(Ravix.Fountain, :client, fn -> client end)
    client
  end

  defp agent(project, allowed),
    do:
      {%{method: "GET", path: "/api/agents/#{project.agent_id}"},
       {200, [],
        %{
          data: %{
            id: project.agent_id,
            inference_credential_id: "owner-set",
            allowed_inference_credential_ids: allowed
          }
        }}}

  test "a clean deployment says so and exits cleanly", ctx do
    fountain(ctx.project, %{"MIX_ENV" => "prod"}, ["GITHUB_TOKEN"])
    Task.run([])

    assert_received {:mix_shell, :info,
                     [
                       "No project holds a provider-named variable or secret, and no agent is open."
                     ]}
  end

  test "each affected project is listed by name, never by value, and the task fails", ctx do
    fountain(ctx.project, %{"OPENAI_API_KEY" => "sk-never-printed"}, ["ANTHROPIC_API_KEY"])

    assert_raise Mix.Error, ~r/1 finding\(s\)/, fn -> Task.run([]) end
    assert_received {:mix_shell, :info, [line]}
    assert line =~ ctx.project.id
    assert line =~ "environment ANTHROPIC_API_KEY, OPENAI_API_KEY; vault none"
    refute line =~ "sk-never-printed"
  end

  test "the release twin prints the same lines and returns how many", ctx do
    fountain(ctx.project, %{}, ["CLAUDE_CODE_OAUTH_TOKEN"])

    output =
      capture_io(fn -> assert Ravix.Release.provider_secrets() == 1 end)

    assert output =~ "environment CLAUDE_CODE_OAUTH_TOKEN; vault none"

    fountain(ctx.project, %{}, [])
    assert capture_io(fn -> assert Ravix.Release.provider_secrets() == 0 end) =~ "No project"
  end

  test "an open agent allowlist is listed, and --close-allowlists closes it once", ctx do
    client = fountain(ctx.project, %{}, [], nil)

    assert_raise Mix.Error, ~r/1 finding\(s\)/, fn -> Task.run([]) end
    assert_received {:mix_shell, :info, [line]}
    assert line == "#{ctx.project.id} agent #{ctx.project.agent_id}: allowlist open (nil)"

    FakeTransport.expect(
      client,
      elem(agent(ctx.project, nil), 0),
      elem(agent(ctx.project, nil), 1)
    )

    FakeTransport.expect(
      client,
      elem(agent(ctx.project, nil), 0),
      elem(agent(ctx.project, nil), 1)
    )

    FakeTransport.expect(
      client,
      %{
        method: "PUT",
        path: "/api/agents/#{ctx.project.agent_id}",
        body: %{allowed_inference_credential_ids: []}
      },
      elem(agent(ctx.project, []), 1)
    )

    for step <- [agent(ctx.project, []), agent(ctx.project, [])] ++ environment(ctx.project),
        do: FakeTransport.expect(client, elem(step, 0), elem(step, 1))

    Task.run(["--close-allowlists"])
    assert_received {:mix_shell, :info, [closed]}
    assert closed == "#{ctx.project.id} agent #{ctx.project.agent_id}: closed"

    assert_received {:mix_shell, :info,
                     [
                       "No project holds a provider-named variable or secret, and no agent is open."
                     ]}
  end

  test "the release closes open allowlists and reports none left", ctx do
    client = fountain(ctx.project, %{}, [], nil)
    Ravix.Release.provider_secret_lines()

    for step <- [
          agent(ctx.project, nil),
          {%{method: "PUT", path: "/api/agents/#{ctx.project.agent_id}"},
           elem(agent(ctx.project, []), 1)},
          agent(ctx.project, [])
        ],
        do: FakeTransport.expect(client, elem(step, 0), elem(step, 1))

    output = capture_io(fn -> assert Ravix.Release.close_open_allowlists() == 0 end)
    assert output =~ "agent #{ctx.project.agent_id}: closed"
  end

  defp environment(project) do
    env = project.environment_id

    [
      {%{method: "GET", path: "/api/environments/#{env}"},
       {200, [], %{data: %{id: env, env_vars: %{}}}}},
      {%{method: "GET", path: "/api/environments/#{env}/secrets"}, {200, [], %{data: []}}}
    ]
  end
end
