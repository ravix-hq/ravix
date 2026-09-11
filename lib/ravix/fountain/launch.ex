defmodule Ravix.Fountain.Launch do
  @moduledoc """
  What Ravix asks Fountain for when it opens a conversation.

  `Ravix.Fountain.create_conversation/2`'s argument, and the reason it is a
  struct is in that function's own doc: *the whole identity goes on every
  attach, not half of it*. A disk is built for `(agent, environment,
  vault)`, and naming only the agent asks for a different identity, one with
  no environment and no vault. Fountain refuses that as
  `sandbox_identity_mismatch` when it can tell; when it cannot, it hands
  back a second machine, which is the single most expensive thing to get
  wrong in this app and does not fail loudly.

  It was a map built inline at the one call site that opens a track, and
  read on the far side with `Map.fetch!/2` for two keys and `Access` for the
  other five. So "I did not send a vault" and "this identity has no vault"
  were the same value, `nil`, arrived at two different ways --- and a caller
  that simply left the key out got the second meaning for free.

  Every field is enforced, including the four that are genuinely optional.
  That is the point: `vault_id: nil` is a sentence somebody wrote, and an
  absent `:vault_id` is not. `Ravix.Fountain.create_conversation/2` still
  leaves a nil or blank field off the wire, which is where "optional"
  belongs --- in the encoding, not in whether the caller had to think about
  it.

    * `agent_id`, `environment_id`, `vault_id` --- the identity.
    * `sandbox_id` --- with one, the conversation attaches to that disk;
      without one it provisions, `sandbox_mode: "persistent"`.
    * `channel_id` --- the track's durable membership of its machine, the
      name Fountain files the conversation under.
    * `title` --- what the conversation is called.
    * `prompt` --- the first turn, sent in the same call. Not an
      optimisation: sending it separately is the one difference that made
      provisioning start answering 422, so it rides along with the launch
      that provisions the box and is nil on an attach, which prompts after.
  """

  @enforce_keys [
    :agent_id,
    :environment_id,
    :vault_id,
    :sandbox_id,
    :channel_id,
    :title,
    :prompt
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          agent_id: String.t(),
          environment_id: String.t() | nil,
          vault_id: String.t() | nil,
          sandbox_id: String.t() | nil,
          channel_id: String.t(),
          title: String.t() | nil,
          prompt: String.t() | nil
        }
end
