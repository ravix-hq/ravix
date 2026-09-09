defmodule Ravix.TracksBoot do
  @moduledoc """
  The four processes the tracks contexts run on, started for a test when
  the application has not started them.

  `Ravix.MachineCache`, `Ravix.Presence` and the follower's registry and
  supervisor belong in `Ravix.Application`. Until they are wired there, a
  test that needs them calls `ensure_running/0`, which starts whichever are
  missing from a process that outlives the test (they are named, global,
  and shared by every async test module, so they must not be linked to any
  one of them). Once the application starts them this is a no-op.
  """

  alias Ravix.Tracks.Follower

  @doc "Start whatever is not running. Idempotent, and safe from concurrent test modules."
  @spec ensure_running() :: :ok
  def ensure_running do
    start(Ravix.MachineCache, fn -> Ravix.MachineCache.start_link([]) end)
    start(Ravix.Presence, fn -> Ravix.Presence.start_link([]) end)

    start(Follower.registry(), fn ->
      Registry.start_link(keys: :unique, name: Follower.registry())
    end)

    start(Follower.supervisor(), fn ->
      DynamicSupervisor.start_link(name: Follower.supervisor(), strategy: :one_for_one)
    end)

    :ok
  end

  defp start(name, starter) do
    if is_nil(Process.whereis(name)) do
      parent = self()

      spawn(fn ->
        case starter.() do
          {:ok, _pid} -> send(parent, {:started, name})
          {:error, {:already_started, _pid}} -> send(parent, {:started, name})
          other -> send(parent, {:failed, name, other})
        end

        Process.sleep(:infinity)
      end)

      receive do
        {:started, ^name} -> :ok
        {:failed, ^name, other} -> raise "could not start #{inspect(name)}: #{inspect(other)}"
      after
        5_000 -> raise "#{inspect(name)} did not start"
      end
    end

    :ok
  end
end
