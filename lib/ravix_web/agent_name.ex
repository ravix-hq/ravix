defmodule RavixWeb.AgentName do
  @moduledoc "Shared product names and project creation choices for coding agents."

  @names %{
    "claude" => "Claude Code",
    "claude-code" => "Claude Code",
    "codex" => "Codex",
    "gemini" => "Gemini CLI",
    "opencode" => "OpenCode",
    "acp" => "ACP"
  }
  @creatable ~w(claude codex)

  def label(runtime), do: Map.get(@names, runtime, runtime)

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
