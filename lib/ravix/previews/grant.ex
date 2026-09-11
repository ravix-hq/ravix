defmodule Ravix.Previews.Grant do
  @moduledoc """
  A browser's admission to one preview.

  The hash of a ticket or of a preview cookie, tied to the Ravix session it
  was minted for. `Ravix.Previews.Store` writes and reads it, and it crosses
  into `lib/ravix_web/`: `RavixWeb.PreviewGateway` authorizes every request
  against one and `RavixWeb.PreviewGateway.Watch` holds one for the life of
  a streaming connection, re-checking it every second.

  The five fields were never at risk of going missing --- `PreviewGrant`
  requires all five, so a grant built short is refused at the write. What a
  struct buys here is the other three things a map cannot do:

    * The store stops keeping a second list of the fields. `grant/1` wrote
      `Map.take(grant, [:hash, :track_id, :session_hash, :expires, :kind])`,
      and a sixth field added to the type would have been dropped there
      silently rather than stored.
    * `RavixWeb.PreviewGateway.Backend`'s `grant()` becomes a type Dialyzer
      can check, so the gateway and the store agree about what
      `get_grant/4` answers and `grant_session/1` takes.
    * `Ravix.PreviewGatewayFake` builds them, and a fake that answers a map
      literal is how a field drifts apart from the one the real store
      returns without a test noticing (see the whole reason the fake holds
      real `Row` and `Track` structs already).

  `kind` is the vocabulary, named here rather than spelled `:ticket |
  :session` in each of the four specs that take one: a ticket is minted by
  Ravix, single-use, and spent for a session; a session is the cookie that
  follows, read on every request. See `Ravix.Previews.Store.disposition/0`
  for the read that spends one.
  """

  @typedoc "A ticket is minted by Ravix and spent once; a session is the cookie it buys."
  @type kind :: :ticket | :session

  @enforce_keys [:hash, :track_id, :session_hash, :expires, :kind]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hash: String.t(),
          track_id: String.t(),
          session_hash: String.t(),
          expires: integer(),
          kind: kind()
        }
end
