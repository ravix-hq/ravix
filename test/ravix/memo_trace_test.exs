defmodule Ravix.MemoTraceTest do
  use Ravix.TraceCase, async: false

  alias Ravix.Fountain.FakeTransport
  alias Ravix.MachineCache
  alias Ravix.Memo
  alias Ravix.Projects.Project
  alias Ravix.Trace

  setup_all do
    Ravix.TracksBoot.ensure_running()
    :ok
  end

  test "a cached Fountain read is a child of its caller, including across rail workers" do
    project = %Project{id: Ecto.UUID.generate(), agent_id: "agent"}

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}}
      ])

    Trace.span("rail", fn ->
      worker = Trace.link_each(fn _ -> MachineCache.conversations(client, project) end)

      assert [{:ok, {:ok, []}}] =
               Task.Supervisor.async_stream_nolink(Ravix.TaskSupervisor, [project], worker)
               |> Enum.to_list()

      assert {:ok, []} = MachineCache.conversations(client, project)
    end)

    assert_receive {:span, request = span(name: "fountain.request")}
    assert_receive {:span, parent = span(name: "rail")}
    assert field(request, :parent_span_id) == field(parent, :span_id)
    assert field(request, :trace_id) == field(parent, :trace_id)
    assert length(FakeTransport.calls(client)) == 1
    refute_received {:span, span(name: "memo.shared")}
  end

  for mode <- [:task, :caller] do
    test "#{mode} loads link late waiters and restore the server context" do
      mode = unquote(mode)
      memo = start_supervised!({Memo, name: __MODULE__})
      parent = self()

      load = fn ->
        Trace.span("provider", fn ->
          send(parent, {:loading, self()})
          receive do: (:go -> :value)
        end)
      end

      fetch = fn name ->
        Task.async(fn ->
          Trace.span(name, fn ->
            Memo.fetch(__MODULE__, :key, load, fn _, now -> now + 5_000 end, run: mode)
          end)
        end)
      end

      first = fetch.("first")
      assert_receive {:loading, worker}
      second = fetch.("second")
      parked(memo, unquote(if(mode == :task, do: 2, else: 1)))
      send(worker, :go)
      assert Task.await(first) == :value
      assert Task.await(second) == :value
      assert_receive {:span, provider = span(name: "provider")}
      assert_receive {:span, shared = span(name: "memo.shared")}
      assert_receive {:span, lead = span(name: "first")}
      assert_receive {:span, waiter = span(name: "second")}
      assert field(provider, :parent_span_id) == field(lead, :span_id)
      assert field(shared, :parent_span_id) == field(lead, :span_id)
      assert [link] = :otel_links.list(field(shared, :links))
      # Link fields use the SDK record, rather than depending on tuple positions.
      fields = Record.extract(:link, from_lib: "opentelemetry/include/otel_span.hrl")
      index = Enum.find_index(Keyword.keys(fields), &(&1 == :span_id)) + 1
      assert elem(link, index) == field(waiter, :span_id)

      :sys.replace_state(memo, fn state ->
        Trace.span("unrelated", fn -> :ok end)
        state
      end)

      assert_receive {:span, span(name: "unrelated", parent_span_id: :undefined)}
    end
  end

  test "a refresh follower owns the next load's trace after invalidation" do
    memo = start_supervised!({Memo, name: __MODULE__})
    parent = self()

    fetch = fn name, now ->
      Task.async(fn ->
        Trace.span(name, fn ->
          Memo.fetch(
            __MODULE__,
            :key,
            fn ->
              Trace.span("provider", fn ->
                send(parent, {:loading, self()})
                receive do: (:go -> name)
              end)
            end,
            fn _, started -> started + 5_000 end,
            now_ms: now,
            newer_than: now
          )
        end)
      end)
    end

    first = fetch.("old", 1)
    assert_receive {:loading, old_worker}
    follower = fetch.("fresh", 2)
    parked(memo, 1, :followers)
    Memo.forget(__MODULE__, :key)
    send(old_worker, :go)
    assert Task.await(first) == "old"
    assert_receive {:span, old_request = span(name: "provider")}
    assert_receive {:span, old_parent = span(name: "old")}
    assert_receive {:loading, new_worker}
    send(new_worker, :go)
    assert Task.await(follower) == "fresh"
    assert_receive {:span, new_request = span(name: "provider")}
    assert_receive {:span, new_parent = span(name: "fresh")}
    assert field(old_request, :parent_span_id) == field(old_parent, :span_id)
    assert field(new_request, :parent_span_id) == field(new_parent, :span_id)
    refute field(new_request, :trace_id) == field(old_request, :trace_id)
    assert Memo.peek(__MODULE__, :key, 2) == {:ok, "fresh"}
  end

  defp parked(memo, count, field \\ :waiters, tries \\ 1_000)
  defp parked(_memo, _count, _field, 0), do: flunk("memo waiter did not arrive")

  defp parked(memo, count, field, tries) do
    state = :sys.get_state(memo)

    if length(Map.fetch!(state.loads.key, field)) == count,
      do: :ok,
      else: parked(memo, count, field, tries - 1)
  end
end
