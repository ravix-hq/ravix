defmodule Ravix.SessionConfig do
  @moduledoc """
  A runtime's ACP session config options (Fountain ADR 0062): reasoning
  effort and Fast, read from what the adapter advertised and sent as a
  prompt's `session_config`.

  Fountain passes the adapter's `SessionConfigOption` list through on the
  conversation (`session_config_options`), after the model and the options
  were applied on the latest turn. Nothing here knows which model offers
  what: claude-agent-acp calls its options `effort` and `fast`, codex-acp
  `reasoning_effort` and `fast-mode`, and both change their values per model.
  The list decides.

  Two kinds of option are offered, and nothing else is settable:

    * **effort**, the first `select` in category `thought_level`, with the
      adapter's own values and names;
    * **fast**, the first option in category `model_config` that is a
      `boolean`, or a `select` whose values are exactly `on` and `off`
      (Fountain's peer translates a boolean for such an adapter).

  The adapter's `mode` (permissions: plan, acceptEdits, auto) is advertised
  on the same list and is deliberately not one of them.

  Ids and values stay strings (or booleans) end to end. They are compared
  against the advertised list, never turned into atoms.
  """

  defmodule Option do
    @moduledoc "One advertised option, as far as Ravix reads it."
    @enforce_keys [:id, :name, :category, :type, :current]
    defstruct @enforce_keys ++ [choices: []]

    @type choice :: %{value: String.t(), name: String.t()}
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            category: String.t() | nil,
            type: :select | :boolean,
            current: String.t() | boolean() | nil,
            choices: [choice()]
          }
  end

  # Fountain's shape rules (ADR 0062), so a stored map never earns a 422.
  @id ~r/\A[A-Za-z0-9._:-]{1,64}\z/
  @max_value 200
  @max_options 16

  @type value :: String.t() | boolean()
  @type config :: %{optional(String.t()) => value()}
  @type controls :: %{effort: Option.t() | nil, fast: Option.t() | nil}

  @doc """
  The options from a conversation's `session_config_options`: nil when the
  field is absent (a Fountain before ADR 0062, or no turn has reported yet),
  so a caller can tell "nothing advertised" from "not known".
  """
  @spec options(term()) :: [Option.t()] | nil
  def options(raw) when is_list(raw), do: Enum.flat_map(raw, &option/1)
  def options(_raw), do: nil

  defp option(%{"id" => id} = raw) when is_binary(id) do
    case type(raw["type"]) do
      nil ->
        []

      type ->
        [
          %Option{
            id: id,
            name: string(raw["name"]) || id,
            category: string(raw["category"]),
            type: type,
            current: current(raw["currentValue"]),
            choices: choices(raw["options"])
          }
        ]
    end
  end

  defp option(_raw), do: []

  defp type("select"), do: :select
  defp type("boolean"), do: :boolean
  defp type(_type), do: nil

  defp current(value) when is_binary(value) or is_boolean(value), do: value
  defp current(_value), do: nil

  # A select's values may come in groups (`{group, name, options}`).
  defp choices(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"options" => nested} when is_list(nested) ->
        choices(nested)

      %{"value" => value} = raw when is_binary(value) ->
        [%{value: value, name: string(raw["name"]) || value}]

      _other ->
        []
    end)
  end

  defp choices(_list), do: []

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  @doc "The effort and Fast options among `options`, either of which may be nil."
  @spec controls([Option.t()] | nil) :: controls()
  def controls(options) when is_list(options) do
    %{
      effort: Enum.find(options, &effort?/1),
      fast: Enum.find(options, &fast?/1)
    }
  end

  def controls(_options), do: %{effort: nil, fast: nil}

  defp effort?(%Option{category: "thought_level", type: :select, choices: [_ | _]}), do: true
  defp effort?(_option), do: false

  defp fast?(%Option{id: "model"}), do: false
  defp fast?(%Option{category: "model_config", type: :boolean}), do: true

  defp fast?(%Option{category: "model_config", type: :select, choices: choices}),
    do: choices |> Enum.map(& &1.value) |> Enum.sort() == ["off", "on"]

  defp fast?(_option), do: false

  @doc """
  A value from the page for option `id`, checked against `controls`: the
  id must be the effort or the Fast option, and the value one the adapter
  listed (effort) or `"true"`/`"false"` (Fast, kept as a boolean).
  """
  @spec choose(controls(), term(), term()) :: {:ok, String.t(), value()} | :error
  def choose(%{effort: %Option{id: id, choices: choices}}, id, value) when is_binary(value) do
    if Enum.any?(choices, &(&1.value == value)), do: {:ok, id, value}, else: :error
  end

  def choose(%{fast: %Option{id: id}}, id, "true"), do: {:ok, id, true}
  def choose(%{fast: %Option{id: id}}, id, "false"), do: {:ok, id, false}
  def choose(_controls, _id, _value), do: :error

  @doc """
  A stored map as Fountain's shape rules allow it: ids of the right form,
  never `model`, string values of at most 200 characters or booleans, and
  at most 16 of them. Anything else is dropped rather than sent to a 422.
  """
  @spec clean(term()) :: config()
  def clean(config) when is_map(config) do
    config
    |> Enum.filter(fn {id, value} -> valid_id?(id) and valid_value?(value) end)
    |> Enum.sort()
    |> Enum.take(@max_options)
    |> Map.new()
  end

  def clean(_config), do: %{}

  defp valid_id?(id), do: is_binary(id) and id != "model" and Regex.match?(@id, id)

  defp valid_value?(value) when is_boolean(value), do: true

  defp valid_value?(value) when is_binary(value),
    do: value != "" and String.length(value) <= @max_value

  defp valid_value?(_value), do: false

  @doc """
  What is in force for `option`: the thread's choice if it made one,
  otherwise what the adapter reported.
  """
  @spec in_force(Option.t() | nil, config()) :: value() | nil
  def in_force(nil, _config), do: nil
  def in_force(%Option{id: id, current: current}, config), do: Map.get(config, id, current)

  @doc "Whether Fast is on: a boolean true, or `on` from a select."
  @spec on?(value() | nil) :: boolean()
  def on?(value), do: value in [true, "on"]

  @doc "The adapter's name for a select's value, or the value itself."
  @spec value_name(Option.t() | nil, value() | nil) :: String.t() | nil
  def value_name(_option, nil), do: nil
  def value_name(_option, value) when is_boolean(value), do: nil

  def value_name(%Option{choices: choices}, value) do
    Enum.find_value(choices, value, &(&1.value == value && &1.name))
  end

  def value_name(nil, value), do: value

  @doc """
  The chip's suffix: the effort's name and "Fast" when on, as far as the
  adapter advertised them. Empty when it advertised neither.
  """
  @spec summary([Option.t()] | nil, config()) :: [String.t()]
  def summary(options, config) do
    %{effort: effort, fast: fast} = controls(options)

    [
      effort && value_name(effort, in_force(effort, config)),
      fast && on?(in_force(fast, config)) && fast.name
    ]
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  What a turn's `config_selection` says, named with `options` where it can:
  the values applied (booleans read as the option's name when on) and the
  options skipped. A refusal is drawn from the turn's failed `config` stage
  (`Ravix.Tracks.Transcript`), which arrives live.
  """
  @spec describe(map() | nil, [Option.t()] | nil) :: %{
          applied: [String.t()],
          skipped: [String.t()]
        }
  def describe(selection, options) do
    selection = selection || %{}
    by_id = Map.new(options || [], &{&1.id, &1})

    # In the order the adapter lists its options, as it applies them.
    order = options |> List.wrap() |> Enum.with_index() |> Map.new(fn {o, i} -> {o.id, i} end)

    applied =
      for {id, value} <-
            Enum.sort_by(selection[:applied] || %{}, fn {id, _} -> {order[id] || 99, id} end),
          name = applied_name(by_id[id], id, value),
          do: name

    %{
      applied: applied,
      skipped: for(id <- selection[:skipped] || [], do: option_name(by_id[id], id))
    }
  end

  defp applied_name(option, id, value) when is_boolean(value) or value in ["on", "off"],
    do: if(on?(value), do: option_name(option, id))

  defp applied_name(option, _id, value), do: value_name(option, value)

  defp option_name(%Option{name: name}, _id), do: name
  defp option_name(nil, id), do: id
end
