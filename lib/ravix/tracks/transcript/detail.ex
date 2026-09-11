defmodule Ravix.Tracks.Transcript.Detail do
  @moduledoc """
  What a tool call *was*, rather than that there was one.

  Built up across both ACP frames: `tool_call` carries the kind and the
  arguments, `tool_call_update` carries the result, and an adapter is free to
  put the diff on either, so `Ravix.Tracks.Transcript.detail/2` merges the two
  rather than trusting one. This was the shape `src/lib/tools.ts` read a
  second time out of the raw update.

  A struct rather than the bare map it was, for the reason the rest of the
  transcript's shapes are: `input` and `paths` and `edits` are read directly
  by the template, and a field that arrives missing renders as a blank chip
  instead of raising where it was built.
  """

  alias Ravix.Tracks.Transcript.Edit

  @typedoc "The ACP tool vocabulary, as `Ravix.Tracks.Transcript` maps it."
  @type kind :: :read | :edit | :delete | :move | :search | :execute | :fetch | :think | :other

  @enforce_keys [:kind, :input, :paths, :edits]
  defstruct kind: :other, input: %{}, paths: [], edits: []

  @type t :: %__MODULE__{
          kind: kind(),
          input: map(),
          paths: [String.t()],
          edits: [Edit.t()]
        }

  @doc "The detail a tool call starts with, before either frame has been read."
  @spec new() :: t()
  def new, do: %__MODULE__{kind: :other, input: %{}, paths: [], edits: []}
end
