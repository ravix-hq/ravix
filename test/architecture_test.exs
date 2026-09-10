Code.require_file("../credo/checks/architecture.ex", __DIR__)

defmodule Ravix.ArchitectureTest do
  use ExUnit.Case, async: true
  alias Ravix.Credo.Architecture

  setup_all do
    if is_nil(Process.whereis(Credo.Supervisor)) do
      {:ok, _} = Application.ensure_all_started(:credo)
    end

    :ok
  end

  defp issues(code, path \\ "lib/ravix/example.ex") do
    code |> Credo.SourceFile.parse(path) |> Architecture.run([])
  end

  test "strict CI actually loads and enables the architecture check" do
    {config, _} = Code.eval_file(".credo.exs")
    default = Enum.find(config.configs, &(&1.name == "default"))
    assert "credo/checks/*.ex" in default.requires
    assert {Architecture, []} in default.checks.enabled
    assert File.read!(".github/workflows/ci.yml") =~ "mix credo --strict"
  end

  test "contexts cannot reference the web layer through aliases, calls or behaviours" do
    for code <- [
          "alias RavixWeb.Error",
          "RavixWeb.Error.from(:oops)",
          "@behaviour RavixWeb.PreviewGateway.Backend",
          "alias RavixWeb.{Error, Router}"
        ] do
      assert [_ | _] = issues(code)
    end

    assert [] = issues("alias Ravix.Accounts")
    assert [] = issues("alias RavixWeb.Error", "lib/ravix_web/example.ex")
    assert [] = issues("RavixWeb.Endpoint.config_change([], [])", "lib/ravix/application.ex")
  end

  test "remote unsafe calls and captures require an ownership explanation" do
    for code <- ["Tracks._unsafe_get_track(id)", "&Tracks._unsafe_get_track/1"] do
      assert [_] = issues(code)
      assert [] = issues("# ownership: scoped Access.track_access(user, id) above\n" <> code)
      assert [_] = issues("# ownership:\n" <> code)
      assert [_] = issues("# ownership: scoped fetch\n" <> String.duplicate("\n", 7) <> code)
    end

    assert [] = issues("_unsafe_get_track(id)")
  end

  test "unsupervised work cannot bypass the guard through aliases or captures" do
    for code <- [
          "Task.start(fn -> :ok end)",
          "Task.async(fn -> :ok end)",
          "Task.async_stream([], & &1)",
          "alias Task, as: Work\nWork.start(fn -> :ok end)",
          "&Task.start/1",
          "import Task",
          "spawn(fn -> :ok end)",
          "Kernel.spawn_link(fn -> :ok end)",
          ":erlang.spawn(fn -> :ok end)"
        ] do
      assert [_ | _] = issues(code)
    end

    assert [] = issues("Task.Supervisor.start_child(Ravix.TaskSupervisor, fn -> :ok end)")
    assert [] = issues("start_async(socket, :load, fn -> :ok end)", "lib/ravix_web/example.ex")
    assert [] = issues("Task.async(fn -> :ok end)", "test/example_test.exs")
  end
end
