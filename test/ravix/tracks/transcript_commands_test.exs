defmodule Ravix.Tracks.Transcript.CommandsTest do
  use ExUnit.Case, async: true

  alias Ravix.Tracks.Transcript.Commands
  alias Ravix.Tracks.Transcript.Commands.Command
  alias Ravix.Tracks.Transcript.Event

  defp acp(update, id \\ 1) do
    line =
      Jason.encode!(%{
        jsonrpc: "2.0",
        method: "session/update",
        params: %{sessionId: "s1", update: update}
      })

    Event.from(%{"id" => id, "kind" => "output", "stream" => "acp", "data" => line})
  end

  defp advertised(commands, id \\ 1),
    do: acp(%{sessionUpdate: "available_commands_update", availableCommands: commands}, id)

  test "reads the agent's command list, with descriptions and input hints" do
    event =
      advertised([
        %{name: "review", description: "Review   the\nbranch", input: %{hint: "what to check"}},
        %{name: "/compact", description: ""},
        %{name: "init", input: nil}
      ])

    assert Commands.from_event(event) == [
             %Command{name: "review", description: "Review the branch", hint: "what to check"},
             %Command{name: "compact"},
             %Command{name: "init"}
           ]
  end

  test "the newest list wins, and an empty one means the agent has none" do
    events = [
      advertised([%{name: "old"}], 1),
      acp(%{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: "hi"}}, 2),
      advertised([%{name: "new"}], 3)
    ]

    assert [%Command{name: "new"}] = Commands.latest(events)
    assert Commands.latest(events ++ [advertised([], 4)]) == []
    assert Commands.latest(Enum.take(events, -2) |> tl()) == [%Command{name: "new"}]
  end

  test "nothing advertised is nil, not an empty list" do
    assert Commands.latest([]) == nil

    assert Commands.latest([
             acp(%{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: "x"}}),
             acp(%{
               sessionUpdate: "current_mode_update",
               currentModeId: "available_commands_update"
             }),
             Event.from(%{"kind" => "stage", "stage" => "turn", "state" => "started"}),
             Event.from(%{
               "kind" => "output",
               "stream" => "acp",
               "data" => "available_commands_update"
             })
           ]) == nil
  end

  test "names that are not a plain word, duplicates and overlong lists are dropped; long text is cut" do
    commands =
      [
        %{name: "has space"},
        %{name: "<script>"},
        %{name: ""},
        %{name: 7},
        "not a map",
        %{
          name: "ok",
          description: String.duplicate("d", 500),
          input: %{hint: String.duplicate("h", 200)}
        },
        %{name: "ok", description: "second"}
      ] ++ for(n <- 1..80, do: %{name: "c#{n}"})

    [first | rest] = Commands.from_event(advertised(commands))

    assert first.name == "ok"
    assert String.length(first.description) == 160
    assert String.length(first.hint) == 80
    assert length(rest) == 49
    refute Enum.any?(rest, &(&1.name == "ok"))
  end

  test "a list among several lines of one event is found" do
    chunk =
      Jason.encode!(%{
        jsonrpc: "2.0",
        method: "session/update",
        params: %{update: %{sessionUpdate: "agent_message_chunk", content: %{type: "text"}}}
      })

    %Event{data: listed} = advertised([%{name: "plan"}])

    event =
      Event.from(%{"kind" => "output", "stream" => "acp", "data" => chunk <> "\n" <> listed})

    assert [%Command{name: "plan"}] = Commands.from_event(event)
  end
end
