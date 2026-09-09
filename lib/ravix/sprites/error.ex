defmodule Ravix.Sprites.Error do
  @moduledoc """
  What Sprites said, or why it could not be asked.

  The status is an HTTP status in the same vocabulary the rest of the server
  uses for user-facing failures: whatever Sprites answered, or 502 when the
  machine could not be reached at all, or 501 when this Sprite lacks a
  feature the previews depend on. The message is written to be shown; the
  panels render it in the empty state where the output would have been.

  It is an exception as well as a value: contexts return it in `{:error, _}`
  tuples, and the body stream in `Ravix.Sprites.Tunnel.HTTP` raises it when a
  connection ends before the body did, because a stream has no other way to
  say so.
  """

  defexception [:status, :message]

  @type t :: %__MODULE__{status: pos_integer(), message: String.t()}

  @doc "Build an error for `status` with a message written to be shown."
  @spec new(pos_integer(), String.t()) :: t()
  def new(status, message) when is_integer(status) and is_binary(message),
    do: %__MODULE__{status: status, message: message}
end
