defmodule RavixWeb.AgentName do
  @moduledoc "Shared product names and project creation choices for coding agents."

  @creatable ~w(claude codex)

  defdelegate label(runtime), to: Ravix.AgentName

  def options, do: Enum.map(@creatable, &{label(&1), &1})

  # Keep an existing choice visible even when it cannot be used for a new project.
  def settings_options(available, current) do
    @creatable
    |> Enum.filter(&(&1 in available))
    |> Kernel.++(List.wrap(current))
    |> Enum.uniq()
    |> Enum.map(&{label(&1), &1})
  end
end
