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

    refute_receive {:span, _}
  end
end
