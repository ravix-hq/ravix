defmodule Ravix.ReleaseDistributionTest do
  @moduledoc """
  A release data step run as a one-off job starts the repository and
  nothing else. Only a second BEAM can show it: in this one the application
  is already running, so "did it start the singletons" has no answer here.

  The peer loads the code and configuration but does not start `:ravix`,
  as `bin/ravix eval` does not, then runs the step. Afterwards nothing of
  the application is running there: no supervisor, no endpoint, no
  `Ravix.Cluster.Singleton` watching for a worker to take over.
  """
  use ExUnit.Case, async: false

  @moduletag :distributed
  @moduletag :capture_log
  @moduletag timeout: 120_000

  @cookie :ravix_release_distribution_test

  setup do
    distribute!()
    {peer, node} = start_peer!()
    on_exit(fn -> stop_peer(peer, node) end)
    %{node: node}
  end

  test "assign_personal_workspaces runs on the repository alone", %{node: node} do
    assert %{applied: false, projects: projects} =
             :erpc.call(node, Ravix.Release, :assign_personal_workspaces, [false], 60_000)

    assert is_list(projects)

    started = :erpc.call(node, Application, :started_applications, [])
    refute List.keymember?(started, :ravix, 0)

    for name <- [Ravix.Supervisor, RavixWeb.Endpoint, Ravix.PubSub, Ravix.Repo],
        do: assert(:erpc.call(node, Process, :whereis, [name]) == nil)

    singletons =
      for pid <- :erpc.call(node, Process, :list, []),
          {:dictionary, dictionary} <- [:erpc.call(node, Process, :info, [pid, :dictionary])],
          Keyword.get(dictionary, :"$initial_call") == {Ravix.Cluster.Singleton, :init, 1},
          do: pid

    assert singletons == []
  end

  defp distribute!(name \\ :"ravix_primary@127.0.0.1") do
    unless Node.alive?() do
      if epmd = System.find_executable("epmd") do
        {_output, _status} = System.cmd(epmd, ["-daemon"], stderr_to_stdout: true)
      end

      {:ok, _pid} = :net_kernel.start(name, %{name_domain: :longnames})
    end

    Node.set_cookie(@cookie)
    :ok
  end

  # Code and configuration only: the application is loaded, not started.
  defp start_peer! do
    {:ok, peer, node} =
      :peer.start(%{
        name: :"ravix_release_peer_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", Atom.to_charlist(@cookie)]
      })

    true = :erpc.call(node, :code, :set_path, [:code.get_path()])

    for {app, _description, _version} <- Application.loaded_applications(),
        {key, value} <- Application.get_all_env(app) do
      :ok = :erpc.call(node, Application, :put_env, [app, key, value])
    end

    true = node != node()
    {peer, node}
  end

  defp stop_peer(peer, node) do
    :peer.stop(peer)
    true = eventually(fn -> node not in Node.list() end)
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp eventually(check, tries \\ 50) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> eventually_after(check, tries)
    end
  end

  defp eventually_after(check, tries) do
    ref = make_ref()
    Process.send_after(self(), ref, 100)

    receive do
      ^ref -> eventually(check, tries - 1)
    end
  end
end
