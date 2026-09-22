defmodule Ravix.Previews.AgentGrant do
  @moduledoc """
  The helper script's admission, for one delivered turn.

  One per thread; the preview service still belongs to the track. The agent on the machine presents it as a bearer token to
  `RavixWeb.Api.PreviewController`, and every field here is re-asked before
  the request is served: the turn is still delivered (`conversation_id`,
  `prompt_id`), the person still has the track (`user_id`), and the machine
  is still the one the grant was written about (`sandbox_id`, `sprite`).
  See `Ravix.Previews.Agent` for where each is checked.

  Unlike `Ravix.Previews.Grant` this one is also stored as a jsonb document,
  so it owns its wire form: `encode/1` and `decode/1` are the only place its
  keys are spelled as strings, and `encode/1` reads the struct's own fields
  rather than `Map.get/2`-ing a key list over whatever it was handed.

  `decode/1` stays lenient, and deliberately: rows the TypeScript wrote
  spell the keys in camel case and a field it never had must read as `nil`
  rather than raise. The check this module adds is at the other end, where
  the grant is *built* --- `Ravix.Previews.Agent.install/4` is the only
  caller and it now names eight fields under `@enforce_keys` instead of
  eight keys nothing counted.

  `conversation_id` is nilable and still enforced: a track with no
  conversation yet is a real state, and a grant that simply omitted the key
  would be indistinguishable from one where it was forgotten.
  """

  alias Ravix.Previews.Row

  @enforce_keys [
    :hash,
    :track_id,
    :user_id,
    :conversation_id,
    :prompt_id,
    :sandbox_id,
    :sprite,
    :expires
  ]
  defstruct @enforce_keys ++ [thread_id: nil]

  @type t :: %__MODULE__{
          hash: String.t(),
          track_id: String.t(),
          thread_id: String.t() | nil,
          user_id: String.t(),
          conversation_id: String.t() | nil,
          prompt_id: String.t(),
          sandbox_id: String.t(),
          sprite: String.t(),
          expires: integer()
        }

  @doc "The `row` document for a grant."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = grant) do
    Map.new(@enforce_keys ++ [:thread_id], fn key ->
      {Atom.to_string(key), Map.fetch!(grant, key)}
    end)
  end

  @doc """
  A grant from its document, whichever spelling it was written in.

  Rows the TypeScript wrote spell the keys in camel case, so the document is
  normalised before it is read; see `Ravix.Previews.Row.normalize_keys/1`.
  """
  @spec decode(map()) :: t()
  def decode(row) do
    row = Row.normalize_keys(row)

    struct!(
      __MODULE__,
      Map.new(@enforce_keys ++ [:thread_id], fn key -> {key, row[Atom.to_string(key)]} end)
    )
  end
end
