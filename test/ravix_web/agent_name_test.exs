defmodule RavixWeb.AgentNameTest do
  use ExUnit.Case, async: true
  alias RavixWeb.AgentName

  test "creation and settings share supported agent products" do
    assert AgentName.options() == [{"Claude Code", "claude"}, {"Codex", "codex"}]

    assert AgentName.settings_options(~w(claude codex gemini opencode acp), "claude") ==
             AgentName.options()

    assert AgentName.settings_options([], nil) == []
  end

  test "saved runtimes keep their product names even outside creation choices" do
    for {runtime, label} <- [
          {"claude-code", "Claude Code"},
          {"gemini", "Gemini CLI"},
          {"opencode", "OpenCode"},
          {"acp", "ACP"},
          {"custom", "custom"}
        ] do
      assert AgentName.settings_options([], runtime) == [{label, runtime}]
    end
  end
end
