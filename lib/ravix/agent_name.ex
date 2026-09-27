defmodule Ravix.AgentName do
  @moduledoc "Product names shared by context errors and UI labels."

  @names %{
    "claude" => "Claude Code",
    "claude-code" => "Claude Code",
    "codex" => "Codex",
    "gemini" => "Gemini CLI",
    "opencode" => "OpenCode",
    "acp" => "ACP"
  }
  def label(runtime), do: Map.get(@names, runtime, runtime)
end
