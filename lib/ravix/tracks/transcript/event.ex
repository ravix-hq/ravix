defmodule Ravix.Tracks.Transcript.Event do
  @moduledoc """
  One line of a conversation's log, parsed once at the Fountain boundary.

  Fountain serves these as string-keyed JSON, and they used to travel that
  way the whole distance: through the follower's broadcast, into a LiveView's
  `handle_info/2`, and out the other side as `event["kind"] == "stage"` in
  three unrelated modules. A key misspelled anywhere along that path reads as
  `nil` and behaves as "not a stage", which is a wrong answer no test can
  see -- there is no key to get wrong, because a map has whatever keys it has.

  So the JSON stops here. `from/1` is the only thing in Ravix that spells
  these keys as strings, and everything downstream reads fields.

  ## Bounded atoms

  `kind` and `stream` come off the wire and are mapped through fixed tables
  with an `:other` fallback, never `String.to_atom/1`: a provider that
  invents a word must not be able to grow the atom table. Their vocabularies
  are small and Ravix matches on them, which is what makes them worth
  closing.

  `stage` and `state` stay strings. Those are Fountain's stage names and
  their lifecycles -- an open vocabulary Ravix reports rather than branches
  on, apart from asking whether a state is `"started"` or `"failed"`.

  ## The prompt

  `prompt` is what somebody asked for, on the one event that can carry it: a
  turn's `turn`/`started` stage, read with `?blocks=true&prompts=true`, has
  a single `prompt` block and nothing else. Every other block Fountain puts
  on an event is its own parse of `data`, which `Ravix.Tracks.Transcript`
  does itself, so those are not kept. The stream never carries prompts; see
  `Ravix.Tracks.Follower` for how a live turn gets its own.
  """

  @enforce_keys [:id, :turn_id, :kind, :stage, :state, :stream, :data, :ts]
  defstruct @enforce_keys ++ [prompt: nil, image_count: 0]

  @pending "pending"

  @kinds %{"output" => :output, "stage" => :stage}
  @streams %{"acp" => :acp, "stdout" => :stdout, "stderr" => :stderr}

  @type kind :: :output | :stage | :other
  @type stream :: :acp | :stdout | :stderr | :other | nil

  @type t :: %__MODULE__{
          id: integer() | nil,
          turn_id: String.t(),
          kind: kind(),
          stage: String.t() | nil,
          state: String.t() | nil,
          stream: stream(),
          data: String.t() | nil,
          ts: term(),
          prompt: String.t() | nil,
          image_count: non_neg_integer()
        }

  @doc """
  An event from what Fountain sent.

  Idempotent: an `%Event{}` is handed back unchanged, so a caller that
  cannot be sure whether a value has been through the boundary yet does not
  have to find out.

  A missing `turn_id` becomes `"pending"` rather than `nil`. Fountain records
  a turn a moment after its first frames arrive, so the events of a turn that
  does not exist yet need somewhere to sit; grouping them under one known id
  is what puts them on screen instead of dropping them.
  """
  @spec from(t() | map()) :: t()
  def from(%__MODULE__{} = event), do: event

  def from(%{} = raw) do
    %__MODULE__{
      id: raw["id"],
      turn_id: turn_id(raw["turn_id"]),
      kind: Map.get(@kinds, raw["kind"], :other),
      stage: raw["stage"],
      state: raw["state"],
      stream: raw["stream"] && Map.get(@streams, raw["stream"], :other),
      data: raw["data"],
      ts: raw["ts"],
      prompt: prompt(raw["blocks"])
    }
  end

  @doc """
  Does this event open a turn? The `turn`/`started` stage, which is the one
  event a turn's prompt is served on.
  """
  @spec starts_turn?(t()) :: boolean()
  def starts_turn?(%__MODULE__{kind: :stage, stage: "turn", state: "started"}), do: true
  def starts_turn?(%__MODULE__{}), do: false

  @doc "The id events with no turn of their own are grouped under."
  @spec pending() :: String.t()
  def pending, do: @pending

  @doc "Did this event end a turn? A turn stage in any state but `started`."
  @spec settles?(t()) :: boolean()
  def settles?(%__MODULE__{kind: :stage, stage: "turn", state: state}), do: state != "started"
  def settles?(%__MODULE__{}), do: false

  @doc "Did this event report a stage that failed?"
  @spec failed_stage?(t()) :: boolean()
  def failed_stage?(%__MODULE__{kind: :stage, state: "failed"}), do: true
  def failed_stage?(%__MODULE__{}), do: false

  defp prompt(blocks) when is_list(blocks) do
    Enum.find_value(blocks, fn
      %{"kind" => "prompt", "body" => body} when is_binary(body) and body != "" -> body
      _other -> nil
    end)
  end

  defp prompt(_absent), do: nil

  defp turn_id(id) when is_binary(id) and id != "", do: id
  defp turn_id(_absent), do: @pending
end
