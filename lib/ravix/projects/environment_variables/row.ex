defmodule Ravix.Projects.EnvironmentVariables.Row do
  @moduledoc "A readable settings row whose value stays out of diagnostic inspection."
  @enforce_keys [:key, :value]
  @derive {Inspect, except: [:value]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{key: String.t() | nil, value: String.t() | nil}

  def new(%{"key" => key, "value" => value}), do: %__MODULE__{key: key, value: value}
  def new(_), do: %__MODULE__{key: nil, value: nil}
end
