defmodule RavixWeb.Live.MachineChangesTest do
  @moduledoc """
  What the Machine page says a save changes (RAV-74), and what it writes:
  the comparison, the counted lines, whether it needs a rebuild, and the
  refusals made before anything is written.
  """
  use ExUnit.Case, async: true

  alias Ravix.Projects.EnvironmentVariables.Row
  alias RavixWeb.Live.MachineChanges

  @saved %{
    setup_script: "npm ci",
    packages: %{"apt" => ["curl", "git"], "npm" => ["pnpm"]},
    env_vars: %{"KEEP" => "1", "CHANGE" => "a", "DROP" => "x"}
  }

  @defaults %{directory: "apps/web", command: "npm start", readiness_path: "/", stop_command: nil}

  defp rows(vars), do: Enum.map(vars, fn {k, v} -> %Row{key: k, value: v} end)

  defp same_rows, do: rows(@saved.env_vars)

  defp plan(environment, rows, secrets \\ [], run \\ %{}),
    do: MachineChanges.plan(@saved, @defaults, environment, rows, secrets, run)

  test "the saved values, as the form holds them" do
    assert MachineChanges.environment_params(@saved) == %{
             "setup_script" => "npm ci",
             "apt" => "curl git",
             "pip" => "",
             "npm" => "pnpm"
           }

    assert MachineChanges.run_params(@defaults) == %{
             "directory" => "apps/web",
             "command" => "npm start",
             "readiness_path" => "/",
             "stop_command" => ""
           }

    assert MachineChanges.run_params(nil)["directory"] == "."
    assert MachineChanges.split_packages("a, b  c,") == ~w(a b c)
    assert MachineChanges.split_packages(nil) == []
    assert MachineChanges.store_label("vault") == "Vault"
    assert MachineChanges.store_label("env") == "Environment"
  end

  test "nothing changed is an empty plan that needs no rebuild" do
    assert {:ok, %{lines: [], environment: nil, secrets: [], run: :keep, rebuild?: false}} =
             plan(
               MachineChanges.environment_params(@saved),
               same_rows(),
               [],
               MachineChanges.run_params(@defaults)
             )
  end

  test "packages, the setup script and variables are summed up and written together" do
    rows = rows(%{"KEEP" => "1", "CHANGE" => "b", "NEW" => "n", "OTHER" => "o"})

    assert {:ok, plan} =
             plan(%{"setup_script" => "make", "apt" => "curl jq, ripgrep", "npm" => ""}, rows)

    assert plan.lines == [
             "+jq +ripgrep −git in apt",
             "−pnpm in npm",
             "setup script edited",
             "2 variables added",
             "1 variable changed",
             "1 variable removed"
           ]

    assert plan.rebuild?

    assert plan.environment == %{
             "setup_script" => "make",
             "packages" => %{"apt" => ~w(curl jq ripgrep), "pip" => [], "npm" => []},
             "env_vars" => %{"KEEP" => "1", "CHANGE" => "b", "NEW" => "n", "OTHER" => "o"},
             "expected_env_vars" => @saved.env_vars
           }
  end

  test "only what changed is written: variables alone leave the environment's others" do
    rows = rows(Map.put(@saved.env_vars, "NEW", "n"))
    assert {:ok, plan} = plan(%{}, rows)
    assert plan.lines == ["1 variable added"]
    assert Map.keys(plan.environment) |> Enum.sort() == ["env_vars", "expected_env_vars"]
  end

  test "secrets are counted by what happens to them, never by value" do
    secrets = [
      %{store: "env", key: "NEW", action: :set, value: "v1", existing: false},
      %{store: "vault", key: "API", action: :set, value: "v2", existing: true},
      %{store: "env", key: "OLD", action: :remove, value: nil, existing: true},
      %{store: "vault", key: "GONE", action: :remove, value: nil, existing: true}
    ]

    assert {:ok, plan} = plan(%{}, same_rows(), secrets)
    assert plan.lines == ["1 secret added", "1 secret replaced", "2 secrets removed"]
    assert plan.rebuild?
    assert plan.environment == nil
    refute Enum.any?(plan.lines, &(&1 =~ "v1" or &1 =~ "v2"))
  end

  test "the run script alone saves without a rebuild; blank clears it" do
    assert {:ok, %{lines: ["run script edited"], rebuild?: false, run: run}} =
             plan(%{}, same_rows(), [], %{"command" => "npm run dev"})

    assert run["command"] == "npm run dev"
    assert run["directory"] == "apps/web"

    assert {:ok, %{lines: ["run script cleared"], run: nil, rebuild?: false}} =
             plan(%{}, same_rows(), [], %{"command" => "  "})

    # With none saved, a blank command is no change at all.
    assert {:ok, %{lines: [], run: :keep}} =
             MachineChanges.plan(@saved, nil, %{}, same_rows(), [], %{
               "directory" => "x",
               "command" => ""
             })
  end

  test "what cannot be saved is refused before anything is written" do
    assert {:error, {:unprocessable, "bad_env_key", _}} =
             plan(%{}, [%Row{key: "not a name", value: "1"}])

    assert {:error, {:unprocessable, "duplicate_env_key", _}} =
             plan(%{}, [%Row{key: "A", value: "1"}, %Row{key: "A", value: "2"}])

    assert {:error, {:unprocessable, "bad_key", "Name each secret, or remove its row."}} =
             plan(%{}, same_rows(), [%{store: "env", key: " ", action: :set, value: "v"}])

    assert {:error, {:unprocessable, "no_secret_value", _}} =
             plan(%{}, same_rows(), [%{store: "env", key: "K", action: :set, value: ""}])

    assert {:error, {:unprocessable, "duplicate_secret", _}} =
             plan(%{}, same_rows(), [
               %{store: "env", key: "K", action: :set, value: "1"},
               %{store: "env", key: "K ", action: :remove, value: nil}
             ])

    # The same name in the two stores is two secrets.
    assert {:ok, %{lines: ["2 secrets added"]}} =
             plan(%{}, same_rows(), [
               %{store: "env", key: "K", action: :set, value: "1"},
               %{store: "vault", key: "K", action: :set, value: "2"}
             ])
  end
end
