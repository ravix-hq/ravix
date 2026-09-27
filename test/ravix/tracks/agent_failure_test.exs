defmodule Ravix.Tracks.AgentFailureTest do
  use ExUnit.Case, async: true
  alias Ravix.Tracks.{AgentFailure, Transcript}
  alias Ravix.Tracks.Transcript.{Block, Detail}
  import Ravix.AgentOutageFixture

  test "five retry notifications followed by systemError beat a misleading end_turn" do
    events = events()

    assert %{code: "agent_provider_unreachable", reason: reason} =
             AgentFailure.detect(events, "codex", [])

    assert reason ==
             "Codex couldn't reach OpenAI (the connection failed after 5 retries). Nothing was changed. Retry."

    [turn] = Transcript.page(events, "codex").turns
    assert [%Block.Failure{body: ^reason}] = turn.blocks
    assert turn.settled?
    streamed = Enum.reduce(events, Transcript.empty("codex"), &Transcript.add_event(&2, &1))
    assert streamed == Transcript.page(events, "codex")
  end

  test "recovered retries and ordinary end_turn are unaffected" do
    recovered = List.delete_at(events(), 6)
    assert AgentFailure.detect(recovered, "codex", []) == nil
    assert [%{blocks: []}] = Transcript.page(recovered, "codex").turns

    normal = [
      %{"kind" => "output", "stream" => "acp", "data" => ~s({"result":{"stopReason":"end_turn"}})}
    ]

    assert AgentFailure.detect(normal, "codex", []) == nil
  end

  test "tool JSON resembling an outage is data, not a terminal protocol signal" do
    error = %{status: "systemError", message: "error decoding response body"}

    for key <- ["rawInput", "rawOutput", "content"] do
      frame = %{method: "session/update", params: %{update: %{key => error}}}
      event = %{"kind" => "output", "stream" => "acp", "data" => Jason.encode!(frame)}
      assert AgentFailure.detect([event], "codex", []) == nil
    end
  end

  test "structured transport failure needs no particular English message" do
    events =
      Enum.map(events(), fn event ->
        Map.update(event, "data", nil, fn data ->
          String.replace(
            data,
            "stream disconnected before completion: Transport error: timeout",
            "unavailable"
          )
        end)
      end)

    assert %{code: "agent_provider_unreachable"} = AgentFailure.detect(events, "codex", [])
  end

  test "decoding errors on terminal systemError are classified without metadata" do
    event = %{
      "kind" => "output",
      "stream" => "acp",
      "data" =>
        Jason.encode!(%{
          result: %{stopReason: "systemError", message: "error decoding response body"}
        })
    }

    for runtime <- ["claude", "claude-code"] do
      assert %{reason: reason} = AgentFailure.detect([event], runtime, [])
      assert reason =~ "Claude Code couldn't reach Anthropic"
      refute reason =~ "OpenAI"
    end

    assert %{reason: reason} = AgentFailure.detect([event], "acp", [])
    assert reason =~ "couldn't reach its model provider"
  end

  test "approval transport failure is distinct from an ordinary permission request" do
    frame = %{
      approvalReview: %{status: "failed", error: %{codexErrorInfo: "responseStreamDisconnected"}}
    }

    event = %{"kind" => "output", "stream" => "acp", "data" => Jason.encode!(frame)}
    assert %{code: "agent_provider_unreachable"} = AgentFailure.detect([event], "codex", [])

    ordinary = %{
      event
      | "data" =>
          Jason.encode!(%{
            method: "session/request_permission",
            params: %{message: "approve the fetch"}
          })
    }

    assert AgentFailure.detect([ordinary], "codex", []) == nil
  end

  test "legacy fallback is exact and does not claim no changes when tools ran" do
    text = %Block.Text{body: "request timed out", started_at: nil, ended_at: nil}
    assert AgentFailure.detect([], "codex", [text])
    refute AgentFailure.detect([], "codex", [%{text | body: "Explain request timed out"}])
    tool = tool("git status", "ok")
    assert %{reason: reason} = AgentFailure.detect(events(), "codex", [tool])
    refute reason =~ "Nothing was changed"
  end

  test "GitHub 401 after an hour shows a notice, unrelated or early 401 does not" do
    old = [%{"ts" => "2026-09-27T10:00:00Z"}, %{"ts" => "2026-09-27T11:00:01Z"}]
    tool = tool("gh pr create", "HTTP 401: Bad credentials (https://api.github.com/graphql)")
    assert AgentFailure.github_notice(old, [tool]) =~ "send another message to refresh it"
    refute AgentFailure.github_notice([], [tool])
    refute AgentFailure.github_notice(old, [tool("curl service.test", "HTTP 401")])

    assert AgentFailure.github_notice([], [
             tool("git fetch", "github.com returned 401: token expired")
           ])
  end

  test "failed bootstrap stays visible" do
    [start | rest] = events()

    start =
      Map.put(start, "blocks", [
        %{
          "kind" => "prompt",
          "body" => "[ravix] Open this track. Make its working directory, then stop."
        }
      ])

    assert [%{visible?: true}] =
             Transcript.visible_turns(Transcript.page([start | rest], "codex"))
  end

  defp tool(name, output) do
    %Block.Tool{
      id: "tool",
      name: name,
      summary: name,
      status: :error,
      output: output,
      started_at: nil,
      ended_at: nil,
      detail: Detail.new()
    }
  end
end
