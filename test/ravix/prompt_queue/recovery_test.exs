defmodule Ravix.PromptQueue.RecoveryTest do
  use ExUnit.Case, async: true

  alias Ravix.PromptQueue.Recovery

  test "only a complete leading recovery block is hidden" do
    track = %Ravix.Tracks.Track{workdir: "/work/track", branch: "ravix/track"}
    preamble = Ravix.Spec.session_recovery_prompt(track, [])
    assert Recovery.visible_prompt(preamble <> "\n\nTyped text") == {"Typed text", true}

    for prompt <- [
          "Typed text",
          preamble,
          "Quoted:\n" <> preamble <> "\n\nTyped text",
          "[ravix: session context restored]\nUnfinished block"
        ] do
      assert Recovery.visible_prompt(prompt) == {prompt, false}
    end
  end
end
