defmodule Ravix.PreviewsFixture do
  @moduledoc """
  The fixture of `server/previews.test.ts`: a scripted Sprites provider, a
  machine that can be swapped, and a clock the test moves.

  The provider is an `Agent` holding the TypeScript fixture's `state`
  (services and their definitions, counts of creates, stops, deletes and
  holds, a readiness answer, a crash count, a port collision, a stop that
  fails, a barrier that stalls service creation). `stub_provider/1` puts
  Mimic stubs on `Ravix.Sprites`, `Ravix.Tracks`, `Ravix.Config`,
  `Ravix.Previews.ready?/2` and `Ravix.Clock` that read and write
  it; because the previews' processes carry `$callers`, the stubs follow
  the test into them.
  """

  import Mimic

  alias Ravix.Clock
  alias Ravix.Previews.Server
  alias Ravix.Sprites.Error
  alias Ravix.Sprites.Shapes

  @type state :: %{
          sandbox: String.t(),
          reads: non_neg_integer(),
          ready: boolean() | (-> boolean()),
          crash: non_neg_integer(),
          collide: boolean(),
          exec_error: term(),
          creates: non_neg_integer(),
          stops: [String.t()],
          deletes: [String.t()],
          holds: [String.t()],
          services: %{String.t() => String.t()},
          definitions: %{String.t() => map()},
          barrier: boolean(),
          fail_stop: boolean(),
          define_conflict: boolean(),
          execs: [[String.t()]],
          now: integer()
        }

  @doc "Assert that the application owns the preview process tree."
  @spec start_tree() :: :ok
  def start_tree do
    for {module, opts} <- Server.child_specs() do
      name = Keyword.get(opts, :name, module)
      if is_nil(Process.whereis(name)), do: raise("preview process not started: #{inspect(name)}")
    end

    :ok
  end

  @doc "A fresh provider state, as the TypeScript fixture built it."
  @spec new_state() :: state()
  def new_state do
    %{
      sandbox: "s1",
      reads: 0,
      ready: true,
      crash: 0,
      collide: false,
      exec_error: nil,
      creates: 0,
      stops: [],
      deletes: [],
      holds: [],
      services: %{},
      definitions: %{},
      barrier: false,
      fail_stop: false,
      define_conflict: false,
      execs: [],
      now: System.system_time(:millisecond)
    }
  end

  @doc "Start the provider agent, linked to the test."
  @spec start_provider() :: pid()
  def start_provider do
    {:ok, pid} = Agent.start_link(fn -> new_state() end)
    pid
  end

  @doc "Read the state."
  @spec state(pid()) :: state()
  def state(pid), do: Agent.get(pid, & &1)

  @doc "Change the state."
  @spec put(pid(), atom(), term()) :: :ok
  def put(pid, key, value), do: Agent.update(pid, &Map.put(&1, key, value))

  @doc "Move the clock forward."
  @spec advance(pid(), integer()) :: :ok
  def advance(pid, ms), do: Agent.update(pid, &Map.update!(&1, :now, fn now -> now + ms end))

  @doc "The current time on the fixture's clock."
  @spec now(pid()) :: integer()
  def now(pid), do: state(pid).now

  @doc "Wait until `fun.(state)` holds, up to a second."
  @spec await(pid(), (state() -> boolean())) :: :ok
  def await(pid, fun, tries \\ 200) do
    cond do
      fun.(state(pid)) ->
        :ok

      tries == 0 ->
        raise "fixture condition did not hold"

      true ->
        Process.sleep(5)
        await(pid, fun, tries - 1)
    end
  end

  @doc """
  Wait for the background work this test started (`act` with "open" or
  "restart" starts the service in a task) so it does not outlive the test's
  database sandbox.
  """
  @spec await_background() :: :ok
  def await_background(tries \\ 400) do
    me = self()

    busy? =
      Ravix.TaskSupervisor
      |> Task.Supervisor.children()
      |> Enum.any?(fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dictionary} -> me in Keyword.get(dictionary, :"$callers", [])
          nil -> false
        end
      end)

    cond do
      not busy? ->
        :ok

      tries == 0 ->
        raise "background preview work did not finish"

      true ->
        Process.sleep(5)
        await_background(tries - 1)
    end
  end

  @doc "Stub configuration, the provider, the machine, readiness and the clock for this test."
  @spec stub_provider(pid()) :: :ok
  def stub_provider(pid) do
    stub(Ravix.Config, :sprites, fn -> %{token: "test", base_url: "http://sprites.test"} end)

    stub(Ravix.Config, :previews, fn ->
      %{domain: "preview.localhost", protocol: :http, public_port: ":5183"}
    end)

    stub(Ravix.Config, :fountain, fn -> %{url: "http://fountain.test", key: "test"} end)
    stub(Ravix.Config, :public_url, fn -> "http://localhost:5183" end)

    stub(Clock, :now_ms, fn -> now(pid) end)
    stub(Clock, :sleep, fn ms -> advance(pid, ms) end)

    stub(Ravix.Tracks, :machine_of, fn _project -> machine(pid) end)
    stub(Ravix.Tracks, :machine_of, fn _project, _opts -> machine(pid) end)
    stub(Ravix.Tracks, :sprite_for, fn sandbox_id -> sandbox_id end)

    stub(Ravix.Previews, :ready?, fn _row, _path ->
      case state(pid).ready do
        fun when is_function(fun, 0) -> fun.()
        answer -> answer
      end
    end)

    stub(Ravix.Sprites, :service, fn _cfg, sprite, name -> {:ok, service(pid, sprite, name)} end)

    stub(Ravix.Sprites, :define_service, fn _cfg, sprite, name, directory, command, port ->
      define_service(pid, sprite, name, directory, command, port)
    end)

    stub(Ravix.Sprites, :service_action, fn _cfg, sprite, name, action ->
      service_action(pid, sprite, name, action)
    end)

    stub(Ravix.Sprites, :service_logs, fn _cfg, _sprite, _name ->
      {:ok, "Error: command not found"}
    end)

    stub(Ravix.Sprites, :activity, fn _cfg, sprite, name, release? ->
      Agent.update(
        pid,
        &Map.update!(&1, :holds, fn holds -> holds ++ ["#{sprite}/#{name}/#{release?}"] end)
      )

      # `activity/4` runs through `exec/4`, so an unreachable machine fails
      # here exactly as it does for the port check.
      state(pid).exec_error |> then(&if &1, do: {:error, &1}, else: :ok)
    end)

    stub(Ravix.Sprites, :exec, fn _cfg, _sprite, argv, _timeout ->
      Agent.update(pid, &Map.update!(&1, :execs, fn execs -> execs ++ [argv] end))

      cond do
        # A machine that is asleep, gone, or unreachable, which is what
        # `Sprites.exec/4` answers with rather than raising.
        error = state(pid).exec_error -> {:error, error}
        state(pid).collide -> {:ok, %{stdout: "", stderr: "Port occupied", code: 1}}
        true -> {:ok, %{stdout: "", stderr: "", code: 0}}
      end
    end)

    :ok
  end

  defp machine(pid) do
    Agent.get_and_update(pid, fn state ->
      {{:ok, %{sandbox_id: state.sandbox}}, %{state | reads: state.reads + 1}}
    end)
  end

  # Through `Ravix.Sprites.Shapes.service/1`, the same function the real
  # `Ravix.Sprites.service/3` decodes with. The fixture scripts the JSON
  # Sprites sends; a struct literal here would be claiming a shape rather
  # than exercising the boundary that builds it.
  defp service(pid, sprite, name) do
    id = "#{sprite}/#{name}"
    state = state(pid)

    case state.services[id] do
      nil ->
        nil

      status ->
        state.definitions[id]
        |> Kernel.||(%{})
        |> Map.merge(%{
          "name" => name,
          "state" => %{"status" => status, "restart_count" => state.crash}
        })
        |> Shapes.service()
    end
  end

  defp define_service(pid, sprite, name, directory, command, port) do
    id = "#{sprite}/#{name}"
    state = state(pid)

    # Live Sprites kept the old sh args after a stop followed by PUT, returning
    # this 200 response. Only deleting the definition makes it accept new args.
    if state.define_conflict and Map.has_key?(state.services, id) do
      {:ok,
       Jason.encode!(%{
         name: name,
         message:
           "Service already running with that command, use POST /v1/services/#{name}/restart if you want to restart it"
       })}
    else
      Agent.update(pid, &Map.update!(&1, :creates, fn n -> n + 1 end))
      await(pid, &(not &1.barrier), 2000)

      definition = %{
        "name" => name,
        "cmd" => "sh",
        "args" => ["-lc", command],
        "dir" => directory,
        "env" => %{"PORT" => Integer.to_string(port), "HOST" => "127.0.0.1"}
      }

      Agent.update(pid, fn state ->
        %{
          state
          | services: Map.put(state.services, id, "running"),
            definitions: Map.put(state.definitions, id, definition)
        }
      end)

      {:ok, "startup logs"}
    end
  end

  defp service_action(pid, sprite, name, action) do
    id = "#{sprite}/#{name}"

    case action do
      :stop -> stop(pid, id)
      :delete -> delete(pid, id)
      :start -> transition(pid, id, "running")
    end
  end

  defp stop(pid, id) do
    if state(pid).fail_stop do
      {:error, Error.new(502, "offline")}
    else
      Agent.update(pid, &%{&1 | stops: &1.stops ++ [id]})
      transition(pid, id, "stopped")
    end
  end

  defp delete(pid, id) do
    Agent.update(pid, &%{&1 | deletes: &1.deletes ++ [id], services: Map.delete(&1.services, id)})
    {:ok, ""}
  end

  defp transition(pid, id, status) do
    Agent.update(pid, &%{&1 | services: Map.put(&1.services, id, status)})
    {:ok, ""}
  end
end
