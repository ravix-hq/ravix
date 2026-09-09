# mint_web_socket 1.0.5 declares its opaque state's fragment as tuple(), but
# new/4 returns fragment: nil. Dialyzer therefore erases its successful return
# and reports this exact cascade as unreachable. The actual HTTP/WebSocket
# handshake and streaming paths are exercised by real socket tests in
# test/ravix/sprites/tunnel_test.exs. Remove these filters when upstream's
# opaque type includes nil. No other warning in this module is ignored.
# Upstream source: https://github.com/elixir-mint/mint_web_socket/blob/v1.0.5/lib/mint/web_socket.ex
[
  {"lib/ravix/sprites/tunnel.ex", "The pattern can never match the type\x20
  {:error,
   %Ravix.Sprites.Error{
     :__exception__ => true,
     :message => binary(),
     :status => pos_integer()
   }}
."},
  {"lib/ravix/sprites/tunnel.ex", "The pattern can never match the type\x20
  {:error, Mint.HTTP1.t() | Mint.HTTP2.t() | Mint.UnsafeProxy.t(),
   %{
     :__exception__ => true,
     :__struct__ =>
       Mint.HTTPError
       | Mint.TransportError
       | Mint.WebSocket.UpgradeFailureError
       | Mint.WebSocketError,
     :headers => [[{binary(), binary()}]],
     :module => _,
     :reason => _,
     :status_code => non_neg_integer()
   }}
."},
  {"lib/ravix/sprites/tunnel.ex", "Function request_port/4 will never be called."},
  {"lib/ravix/sprites/tunnel.ex", "Function await_connected/5 will never be called."},
  {"lib/ravix/sprites/tunnel.ex", "Function acknowledgement/1 will never be called."},
  {"lib/ravix/sprites/tunnel.ex", "Function refuse/2 will never be called."},
  {"lib/ravix/sprites/tunnel.ex", "Function format/1 will never be called."}
]
