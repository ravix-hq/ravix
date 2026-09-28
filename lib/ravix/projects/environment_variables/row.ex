defmodule Ravix.Projects.EnvironmentVariables.Row do
  @moduledoc "A readable settings row whose value stays out of diagnostic inspection."
  @enforce_keys [:key, :value]
  @derive {Inspect, except: [:value]}
  defstruct @enforce_keys

  def new(%{"key" => key, "value" => value}), do: %__MODULE__{key: key, value: value}
end
