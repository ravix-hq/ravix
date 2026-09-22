defmodule Ravix.MachineCacheTest do
  use ExUnit.Case, async: true

  alias Ravix.Fountain.FakeTransport
  alias Ravix.Fountain.Shapes.Conversation
  alias Ravix.MachineCache
  alias Ravix.Projects.Project

  # The JSON Fountain serves, and the shape `Ravix.Fountain` turns it into.
  @row %{"id" => "c1", "sandbox_id" => "s1", "status" => "idle", "inserted_at" => "2026-09-07"}
  @conversation %Conversation{
    id: "c1",
    status: :idle,
    sandbox_id: "s1",
    sprite_name: nil,
    inserted_at: "2026-09-07",
    last_active_at: nil,
    turn_count: nil
  }

  setup_all do
    Ravix.TracksBoot.ensure_running()
    :ok
  end

  # A project per test, so the memo (keyed on the client and the project) is
  # this test's own even though the table is shared by every async module.
  setup do
    n = System.unique_integer([:positive])
    {:ok, project: %Project{id: "p-#{n}", agent_id: "a-#{n}"}}
  end

  defp fountain(project, responses) do
    FakeTransport.client(
      Enum.map(responses, fn body ->
        {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
         {200, [], %{data: body}}}
      end)
    )
  end

  test "a burst of reads within the TTL is one call, and concurrent misses share it", %{
    project: project
  } do
    client = fountain(project, [[@row]])

    results =
      [0, 0, 1_000]
      |> Enum.map(&Task.async(fn -> MachineCache.conversations(client, project, now_ms: &1) end))
      |> Task.await_many()

    assert results == [{:ok, [@conversation]}, {:ok, [@conversation]}, {:ok, [@conversation]}]
    # Narrowed to the project's agent, never the whole account.
    assert [%{query: %{"agent_id" => agent}}] = FakeTransport.calls(client)
    assert agent == project.agent_id
  end

  test "the memo expires", %{project: project} do
    client = fountain(project, [[@row], []])
    ttl = MachineCache.ttl_ms()
    assert {:ok, [@conversation]} = MachineCache.conversations(client, project, now_ms: 0)
    assert {:ok, [@conversation]} = MachineCache.conversations(client, project, now_ms: ttl - 1)
    assert {:ok, []} = MachineCache.conversations(client, project, now_ms: ttl)
    assert length(FakeTransport.calls(client)) == 2
  end

  test "a fresh read asks Fountain and refreshes the memo for everyone else", %{project: project} do
    client = fountain(project, [[@row], []])
    assert {:ok, [@conversation]} = MachineCache.conversations(client, project, now_ms: 0)
    assert {:ok, []} = MachineCache.conversations(client, project, now_ms: 1, fresh: true)
    assert {:ok, []} = MachineCache.conversations(client, project, now_ms: 2)
    assert length(FakeTransport.calls(client)) == 2
  end

  test "fresh reads arriving during a fresh read share it rather than restarting it", %{
    project: project
  } do
    me = self()

    # Fountain answers when told to, so that the second and third readers
    # provably arrive while the first read is in flight.
    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations"},
         fn _call ->
           send(me, {:asked, self()})

           receive do
             :answer -> {200, [], %{data: [@row]}}
           after
             1_000 -> {500, [], %{error: "never released"}}
           end
         end}
      ])

    opts = [now_ms: 0, fresh: true]
    first = Task.async(fn -> MachineCache.conversations(client, project, opts) end)
    assert_receive {:asked, fountain}, 1_000

    # A `:turn` on the hub reaches every open page on the project and each
    # asks for the list afresh. Deleting the key on each ask, as this used
    # to, disowned the read in flight and started one per page.
    rest =
      for _ <- 1..2, do: Task.async(fn -> MachineCache.conversations(client, project, opts) end)

    parked_on_the_first(client, project)

    send(fountain, :answer)
    assert Task.await(first) == {:ok, [@conversation]}
    assert Task.await_many(rest) == [{:ok, [@conversation]}, {:ok, [@conversation]}]
    assert length(FakeTransport.calls(client)) == 1
  end

  # Wait for the two later readers to be parked behind the first's load,
  # which they do by messaging the memo and which nothing else reports.
  defp parked_on_the_first(client, project) do
    key = {client.base_url, :conversations, project.id, project.agent_id}

    Enum.reduce_while(1..400, :timeout, fn _, _ ->
      case :sys.get_state(MachineCache).loads[key] do
        %{waiters: waiters} when length(waiters) == 3 -> {:halt, :ok}
        _ -> Process.sleep(5) && {:cont, :timeout}
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("the later readers never joined the first read")
    end
  end

  test "forgetting a project drops its memo and nobody else's", %{project: project} do
    other = %Project{id: project.id <> "-other", agent_id: project.agent_id <> "-other"}

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
         {200, [], %{data: [@row]}}},
        {%{method: "GET", path: "/api/conversations", query: %{agent_id: other.agent_id}},
         {200, [], %{data: []}}},
        {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
         {200, [], %{data: []}}}
      ])

    assert {:ok, [@conversation]} = MachineCache.conversations(client, project, now_ms: 0)
    assert {:ok, []} = MachineCache.conversations(client, other, now_ms: 0)
    MachineCache.forget_project(project.id)
    assert {:ok, []} = MachineCache.conversations(client, project, now_ms: 1)
    assert {:ok, []} = MachineCache.conversations(client, other, now_ms: 1)
    assert length(FakeTransport.calls(client)) == 3
  end

  test "an environment stands for a minute and is dropped when it is forgotten" do
    id = "env-#{System.unique_integer([:positive])}"

    body = fn script ->
      {%{method: "GET", path: "/api/environments/#{id}"},
       {200, [], %{data: %{"id" => id, "setup_script" => script}}}}
    end

    client = FakeTransport.client([body.(""), body.("make setup"), body.("make setup")])
    ttl = MachineCache.environment_ttl_ms()

    # `Ravix.Tracks.get/2` reads this on every refresh of every open page, so
    # the burst a turn produces has to cost one call, not one each.
    assert {:ok, %{"setup_script" => ""}} = MachineCache.environment(client, id, now_ms: 0)
    assert {:ok, %{"setup_script" => ""}} = MachineCache.environment(client, id, now_ms: ttl - 1)
    assert length(FakeTransport.calls(client)) == 1

    # Saving settings is the only thing that changes the answer, and it says
    # so rather than leaving the ribbon offering a script somebody just wrote.
    MachineCache.forget_environment(id)

    assert {:ok, %{"setup_script" => "make setup"}} =
             MachineCache.environment(client, id, now_ms: ttl - 1)

    assert length(FakeTransport.calls(client)) == 2

    # The minute is the backstop for a save made on another instance.
    assert {:ok, %{"setup_script" => "make setup"}} =
             MachineCache.environment(client, id, now_ms: 2 * ttl)

    assert length(FakeTransport.calls(client)) == 3
  end

  test "two clients do not share an answer", %{project: project} do
    f = fountain(project, [[@row]])
    g = fountain(project, [[]])
    assert {:ok, [@conversation]} = MachineCache.conversations(f, project, now_ms: 0)
    assert {:ok, []} = MachineCache.conversations(g, project, now_ms: 0)
  end

  test "a failed read is not remembered", %{project: project} do
    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations"}, {500, [], %{error: "boom"}}},
        {%{method: "GET", path: "/api/conversations"}, {500, [], %{error: "boom"}}}
      ])

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, %Ravix.Fountain.Error{status: 500}} =
               MachineCache.conversations(client, project, now_ms: 0)

      assert {:error, %Ravix.Fountain.Error{status: 500}} =
               MachineCache.conversations(client, project, now_ms: 1)
    end)

    assert length(FakeTransport.calls(client)) == 2
  end

  test "a sprite name stands for a minute; a missing one only briefly", %{project: project} do
    client = fountain(project, [])
    sprite_ttl = MachineCache.sprite_ttl_ms()
    ttl = MachineCache.ttl_ms()
    {:ok, counter} = Agent.start_link(fn -> %{named: 0, missing: 0} end)
    sandbox = "s-#{System.unique_integer([:positive])}"

    named = fn ->
      Agent.update(counter, &Map.update!(&1, :named, fn n -> n + 1 end))
      "sprite-1"
    end

    assert "sprite-1" == MachineCache.sprite_name(client, sandbox, named, now_ms: 0)
    assert "sprite-1" == MachineCache.sprite_name(client, sandbox, named, now_ms: sprite_ttl - 1)
    assert Agent.get(counter, & &1.named) == 1
    assert "sprite-1" == MachineCache.sprite_name(client, sandbox, named, now_ms: sprite_ttl)
    assert Agent.get(counter, & &1.named) == 2

    missing = fn ->
      Agent.update(counter, &Map.update!(&1, :missing, fn n -> n + 1 end))
      nil
    end

    assert is_nil(MachineCache.sprite_name(client, sandbox <> "-2", missing, now_ms: 0))
    assert is_nil(MachineCache.sprite_name(client, sandbox <> "-2", missing, now_ms: ttl - 1))
    assert Agent.get(counter, & &1.missing) == 1
    assert is_nil(MachineCache.sprite_name(client, sandbox <> "-2", missing, now_ms: ttl))
    assert Agent.get(counter, & &1.missing) == 2
  end

  describe "machine_of/3" do
    test "the newest live conversation with a sandbox names the machine", %{project: project} do
      rows = [
        %{
          "id" => "old",
          "sandbox_id" => "s-old",
          "status" => "idle",
          "inserted_at" => "2026-09-01T00:00:00Z"
        },
        %{
          "id" => "ended",
          "sandbox_id" => "s-ended",
          "status" => "ended",
          "inserted_at" => "2026-09-09T00:00:00Z"
        },
        %{
          "id" => "new",
          "sandbox_id" => "s-new",
          "status" => "running",
          "inserted_at" => "2026-09-08T00:00:00Z"
        },
        %{
          "id" => "none",
          "sandbox_id" => nil,
          "status" => "idle",
          "inserted_at" => "2026-09-10T00:00:00Z"
        }
      ]

      client = fountain(project, [rows])
      assert {:ok, %{sandbox_id: "s-new"}} = MachineCache.machine_of(client, project, now_ms: 0)
    end

    test "no live conversation is no machine, not an error", %{project: project} do
      client = fountain(project, [[]])
      assert {:ok, nil} = MachineCache.machine_of(client, project, now_ms: 0)
    end
  end

  describe "sprite_for/3" do
    test "reads the sandbox and answers nil when Fountain cannot", %{project: project} do
      client =
        FakeTransport.client([
          {%{method: "GET", path: "/api/sandboxes/s-yes"},
           {200, [], %{data: %{id: "s-yes", sprite_name: "sprite-9"}}}},
          {%{method: "GET", path: "/api/sandboxes/s-no"}, {404, [], %{error: "not_found"}}}
        ])

      _ = project

      ExUnit.CaptureLog.capture_log(fn ->
        assert "sprite-9" == MachineCache.sprite_for(client, "s-yes", now_ms: 0)
        assert is_nil(MachineCache.sprite_for(client, "s-no", now_ms: 0))
      end)
    end
  end
end
