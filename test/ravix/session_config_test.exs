defmodule Ravix.SessionConfigTest do
  use ExUnit.Case, async: true

  alias Ravix.SessionConfig
  alias Ravix.SessionConfig.Option

  # As claude-agent-acp 0.81.2 advertises them (Fountain ADR 0062's live check).
  @claude [
    %{
      "id" => "effort",
      "name" => "Effort",
      "category" => "thought_level",
      "type" => "select",
      "currentValue" => "default",
      "options" => [
        %{"value" => "default", "name" => "Default"},
        %{"value" => "high", "name" => "High"},
        %{"value" => "max", "name" => "Max"}
      ]
    },
    %{
      "id" => "fast",
      "name" => "Fast mode",
      "category" => "model_config",
      "type" => "boolean",
      "currentValue" => false
    },
    %{
      "id" => "mode",
      "name" => "Mode",
      "category" => "mode",
      "type" => "select",
      "currentValue" => "default",
      "options" => [%{"value" => "default"}, %{"value" => "auto"}]
    }
  ]

  # codex-acp 1.10.0: other ids, grouped values, and a select-only fast.
  @codex [
    %{
      "id" => "reasoning_effort",
      "name" => "Reasoning effort",
      "category" => "thought_level",
      "type" => "select",
      "currentValue" => "medium",
      "options" => [
        %{
          "group" => "g",
          "name" => "Levels",
          "options" => [
            %{"value" => "medium", "name" => "Medium"},
            %{"value" => "high", "name" => "High"}
          ]
        }
      ]
    },
    %{
      "id" => "fast-mode",
      "name" => "Fast mode",
      "category" => "model_config",
      "type" => "select",
      "currentValue" => "off",
      "options" => [%{"value" => "on"}, %{"value" => "off"}]
    }
  ]

  test "nil when nothing was advertised, and malformed options are dropped" do
    assert SessionConfig.options(nil) == nil
    assert SessionConfig.options([%{"id" => 3}, %{"id" => "x", "type" => "slider"}, "junk"]) == []
    assert SessionConfig.controls(nil) == %{effort: nil, fast: nil}
  end

  test "effort and Fast come from the categories, with the adapter's own ids and names" do
    %{effort: effort, fast: fast} = @claude |> SessionConfig.options() |> SessionConfig.controls()
    assert %Option{id: "effort", name: "Effort", current: "default"} = effort
    assert Enum.map(effort.choices, & &1.name) == ["Default", "High", "Max"]
    assert %Option{id: "fast", type: :boolean, current: false} = fast

    %{effort: effort, fast: fast} = @codex |> SessionConfig.options() |> SessionConfig.controls()
    assert effort.id == "reasoning_effort"
    assert Enum.map(effort.choices, & &1.value) == ["medium", "high"]
    assert %Option{id: "fast-mode", type: :select} = fast
  end

  test "the adapter's \"Xhigh\" is named in words, and its value is kept" do
    [effort] =
      SessionConfig.options([
        %{
          "id" => "effort",
          "category" => "thought_level",
          "type" => "select",
          "options" => [
            %{"value" => "high", "name" => "High"},
            %{"value" => "xhigh", "name" => "Xhigh"},
            %{"value" => "x-high"}
          ]
        }
      ])

    assert effort.choices == [
             %{value: "high", name: "High"},
             %{value: "xhigh", name: "Extra high"},
             %{value: "x-high", name: "Extra high"}
           ]

    assert SessionConfig.summary([effort], %{"effort" => "xhigh"}) == ["Extra high"]
  end

  test "only advertised effort values and a boolean Fast are chosen; mode never is" do
    claude = @claude |> SessionConfig.options() |> SessionConfig.controls()
    assert SessionConfig.choose(claude, "effort", "max") == {:ok, "effort", "max"}
    assert SessionConfig.choose(claude, "fast", "true") == {:ok, "fast", true}
    assert SessionConfig.choose(claude, "fast", "false") == {:ok, "fast", false}

    for {id, value} <- [
          {"effort", "ludicrous"},
          {"effort", "xhigh"},
          {"mode", "auto"},
          {"fast", "on"},
          {"reasoning_effort", "high"},
          {"effort", nil},
          {nil, "high"}
        ],
        do: assert(SessionConfig.choose(claude, id, value) == :error)

    codex = @codex |> SessionConfig.options() |> SessionConfig.controls()

    assert SessionConfig.choose(codex, "reasoning_effort", "high") ==
             {:ok, "reasoning_effort", "high"}

    assert SessionConfig.choose(codex, "fast-mode", "true") == {:ok, "fast-mode", true}
    assert SessionConfig.choose(%{effort: nil, fast: nil}, "effort", "high") == :error
  end

  test "a stored map is cut to Fountain's shape rules" do
    many = Map.new(1..20, &{"opt#{&1}", "x"})

    assert SessionConfig.clean(%{
             "effort" => "high",
             "fast" => true,
             "model" => "x",
             "bad id!" => "x",
             "empty" => "",
             "long" => String.duplicate("x", 201),
             "number" => 3
           }) == %{"effort" => "high", "fast" => true}

    assert map_size(SessionConfig.clean(many)) == 16
    assert SessionConfig.clean(nil) == %{}
  end

  test "the chip names what is in force: the thread's choice, else the adapter's" do
    options = SessionConfig.options(@claude)
    assert SessionConfig.summary(options, %{}) == ["Default"]

    assert SessionConfig.summary(options, %{"effort" => "high", "fast" => true}) == [
             "High",
             "Fast mode"
           ]

    assert SessionConfig.summary(SessionConfig.options(@codex), %{"fast-mode" => "on"}) == [
             "Medium",
             "Fast mode"
           ]

    assert SessionConfig.summary(nil, %{"effort" => "high"}) == []
  end

  test "a turn's selection reads as names, with skipped options named too" do
    options = SessionConfig.options(@claude)

    assert SessionConfig.describe(
             %{applied: %{"effort" => "high", "fast" => true}, skipped: ["reasoning_effort"]},
             options
           ) == %{applied: ["High", "Fast mode"], skipped: ["reasoning_effort"]}

    assert SessionConfig.describe(%{applied: %{"fast" => false}, skipped: ["fast"]}, options) ==
             %{applied: [], skipped: ["Fast mode"]}

    assert SessionConfig.describe(nil, options) == %{applied: [], skipped: []}
  end
end
