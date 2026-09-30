defmodule Ravix.LiveSocketTraceTest do
  use Ravix.TraceCase, async: false

  alias Phoenix.LiveView.Socket

  for transport <- [:websocket, :longpoll] do
    test "records the actual #{transport} transport on socket connect" do
      assert {:ok, _} =
               Socket.connect(%{
                 endpoint: RavixWeb.Endpoint,
                 transport: unquote(transport),
                 params: %{"vsn" => "2.0.0", "_csrf_token" => "must-not-export"},
                 connect_info: %{session: %{"live_socket_id" => "must-not-export"}},
                 options: [serializer: [{Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}]]
               })

      recorded = await_span("live_view.connect")

      assert attributes(recorded) == %{
               "ravix.live_view.transport" => Atom.to_string(unquote(transport))
             }
    end
  end

  test "ignores rejected connections, other sockets and unknown transports" do
    # The exporter is global, so a process some earlier test left running (a
    # follower settling a turn, say) can still finish a span into this mailbox.
    # "No span at all" would count that one, so this one stands in for it.
    {pid, ref} = spawn_monitor(fn -> Ravix.Trace.span("ravix.repo.query", fn -> :ok end) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    # The handler runs in the caller, so anything it records is a child of this
    # span, and ends -- and is exported -- before it does.
    trace_id =
      Ravix.Trace.span("test.socket_connected", fn ->
        for metadata <- [
              %{user_socket: Socket, result: :error, transport: :websocket},
              %{user_socket: OtherSocket, result: :ok, transport: :websocket},
              %{user_socket: Socket, result: :ok, transport: :unknown}
            ] do
          :telemetry.execute(
            [:phoenix, :socket_connected],
            %{duration: 0},
            Map.merge(%{endpoint: RavixWeb.Endpoint, log: false}, metadata)
          )
        end

        :otel_span.trace_id(OpenTelemetry.Tracer.current_span_ctx())
      end)

    assert children(trace_id) == []
  end

  # Spans in this test's trace that finished before its root, by name.
  defp children(trace_id, found \\ []) do
    receive do
      {:span, recorded} ->
        cond do
          field(recorded, :trace_id) != trace_id -> children(trace_id, found)
          span_name(recorded) == "test.socket_connected" -> Enum.reverse(found)
          true -> children(trace_id, [span_name(recorded) | found])
        end
    after
      2_000 -> flunk("The test's own span never finished")
    end
  end
end
