# mint_web_socket (1.0.5 and still 1.0.6) declares its opaque state's fragment
# as tuple(), but new/4 returns fragment: nil. Dialyzer therefore erases its
# successful return and reports this exact cascade as unreachable: the upgrade
# in lib/ravix/sprites/web_socket.ex, and everything its two callers --- the
# preview tunnel and the interactive terminal --- do once it has succeeded.
# The actual HTTP/WebSocket handshake and streaming paths are exercised by
# real socket tests in test/ravix/sprites/tunnel_test.exs and
# test/ravix/sprites/pty_test.exs. Remove these filters when upstream's opaque
# type includes nil. No other warning in these modules is ignored.
# Upstream source: https://github.com/elixir-mint/mint_web_socket/blob/v1.0.6/lib/mint/web_socket.ex
[
  {"lib/ravix/sprites/web_socket.ex", "The pattern can never match the type\x20
  {:error,
   %Ravix.Sprites.Error{
     :__exception__ => true,
     :message => binary(),
     :status => pos_integer()
   }}
."},
  {"lib/ravix/sprites/web_socket.ex", "The pattern can never match the type\x20
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
  {"lib/ravix/sprites/tunnel.ex", "The pattern can never match the type\x20
  {:error,
   %Ravix.Sprites.Error{
     :__exception__ => true,
     :message => binary(),
     :status => pos_integer()
   }}
."},
  {"lib/ravix/sprites/tunnel.ex", "Function request_port/2 will never be called."},
  {"lib/ravix/sprites/tunnel.ex", "Function await_connected/3 will never be called."},
  # Same cascade, one frame further: `await_more/2` exists only because inlining
  # it puts `await_connected/3` past Credo's nesting limit, and it is
  # unreachable to Dialyzer for the identical upstream reason as its caller,
  # which is already listed above it (#15).
  {"lib/ravix/sprites/tunnel.ex", "Function await_more/2 will never be called."},
  {"lib/ravix/sprites/tunnel.ex", "Function acknowledgement/1 will never be called."},
  {"lib/ravix/sprites/tunnel.ex", "Function refuse/2 will never be called."},
  {"lib/ravix/sprites/tunnel.ex", "Function format/1 will never be called."},
  # The terminal's side of the same cascade: the successful upgrade, and the
  # one function only reachable after it.
  {"lib/ravix/sprites/pty.ex", "The pattern can never match the type\x20
  {:error,
   %Ravix.Sprites.Error{
     :__exception__ => true,
     :message => binary(),
     :status => pos_integer()
   }}
."},
  {"lib/ravix/sprites/pty.ex", "Function failed/2 will never be called."}
]
