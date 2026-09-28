defmodule Ravix.TranscriptFixture do
  @moduledoc "ACP regression wire shapes and a synthetic long tool-heavy conversation."

  def update(shape),
    do: Jason.encode!(%{jsonrpc: "2.0", method: "session/update", params: %{update: shape}})

  def text(body),
    do: %{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: body}}

  def thought(body),
    do: %{sessionUpdate: "agent_thought_chunk", content: %{type: "text", text: body}}

  def call(id),
    do: %{sessionUpdate: "tool_call", toolCallId: id, title: "Read file", kind: "read"}

  def result(id),
    do: %{
      sessionUpdate: "tool_call_update",
      toolCallId: id,
      status: "completed",
      content: [%{type: "content", content: %{type: "text", text: "defmodule Example do\nend"}}]
    }

  def output(id, shape, turn \\ "t"),
    do: %{
      "id" => id,
      "turn_id" => turn,
      "kind" => "output",
      "stream" => "acp",
      "data" => update(shape)
    }

  def stage(id, state),
    do: %{"id" => id, "turn_id" => "t", "kind" => "stage", "stage" => "turn", "state" => state}

  def sample(count) do
    calls = div(count, 4)

    shapes =
      Enum.flat_map(1..calls, fn n ->
        [
          call("tool-#{n}"),
          thought("Inspecting module #{n}."),
          text("Checking the implementation.\n")
        ]
      end) ++ Enum.map(1..calls, &result("tool-#{&1}"))

    [stage(1, "started")] ++
      (shapes
       |> Enum.take(count - 2)
       |> Enum.with_index(2)
       |> Enum.map(fn {shape, id} -> output(id, shape) end)) ++
      [stage(count, "completed")]
  end

  def corpus do
    plan = %{sessionUpdate: "plan", entries: [%{content: "Inspect", status: "in_progress"}]}

    shapes = [
      text("Hel"),
      text("lo"),
      thought("Think"),
      thought("ing"),
      call("a"),
      call("b"),
      plan,
      text("between"),
      result("a"),
      %{plan | entries: []},
      text("after clearing"),
      result("b"),
      call("a"),
      result("a"),
      result("orphan"),
      %{plan | entries: [%{content: "Done", status: "completed"}]}
    ]

    tools =
      ([stage(1, "started")] ++ Enum.with_index(shapes, 2))
      |> Enum.map(fn
        {shape, id} -> output(id, shape)
        event -> event
      end)

    %{
      "tools-plans-text" => tools ++ [stage(30, "completed")],
      "codex-outage" => Ravix.AgentOutageFixture.events(),
      "duplicates-out-of-order" => [
        output(3, text("third")),
        output(1, text("first")),
        output(2, text("second")),
        output(2, text("ignored"))
      ],
      "interleaved-turns" => [
        output(1, call("same"), "a"),
        output(2, call("same"), "b"),
        output(3, result("same"), "a"),
        output(4, result("same"), "b")
      ],
      "legacy-and-raw" => [
        %{
          "id" => 1,
          "turn_id" => "t",
          "kind" => "output",
          "stream" => "stdout",
          "data" => "legacy"
        },
        %{
          "id" => 2,
          "turn_id" => "t",
          "kind" => "output",
          "stream" => "acp",
          "data" => "not JSON\n"
        },
        Map.put(stage(3, "failed"), "data", "")
      ]
    }
  end

  def public(%_{} = struct),
    do:
      struct
      |> Map.from_struct()
      |> Map.drop([
        :fold,
        :failure,
        :conversation_id,
        :history,
        :oldest_event_id,
        :oldest_conversation_id
      ])
      |> public()

  def public(map) when is_map(map),
    do:
      Map.new(map, fn {key, value} ->
        {key, public(payload(key, value))}
      end)

  def public(list) when is_list(list), do: Enum.map(list, &public/1)
  def public(value), do: value

  defp payload(key, value) when key in [:data, :details] and is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp payload(_key, value), do: value
end
