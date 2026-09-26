defmodule RavixWeb.PlanGraphTest do
  use ExUnit.Case, async: true
  alias RavixWeb.Live.PlanGraph

  defp item(id, deps, status \\ :unassigned),
    do: %{id: id, title: id, dependencies: deps, status: status}

  defp placed(layout), do: Map.new(layout.nodes, &{&1.item.id, {&1.column, &1.row}})

  test "columns follow the longest dependency chain, so a diamond's join waits for its longest side" do
    layout =
      PlanGraph.layout([
        item("adr", []),
        item("socket", ["adr"]),
        item("daemon", ["socket"]),
        item("forward", ["socket"]),
        item("builds", ["daemon", "forward", "adr"])
      ])

    assert %{
             "adr" => {0, 0},
             "socket" => {1, 0},
             "daemon" => {2, 0},
             "forward" => {2, 1},
             "builds" => {3, 0}
           } = placed(layout)

    assert length(layout.edges) == 6
    assert Enum.all?(layout.edges, fn e -> String.starts_with?(e.path, "M") end)
    assert layout.width == 4 * layout.node_width + 3 * 44
    assert layout.height == 2 * layout.node_height + 14
  end

  test "rows keep plan order, then sit near their dependencies" do
    layout =
      PlanGraph.layout([
        item("a", []),
        item("b", []),
        item("from-b", ["b"]),
        item("from-a", ["a"])
      ])

    assert %{"a" => {0, 0}, "b" => {0, 1}, "from-a" => {1, 0}, "from-b" => {1, 1}} =
             placed(layout)
  end

  test "an edge takes its dependency's status, and unknown ids draw nothing" do
    layout = PlanGraph.layout([item("a", [], :done), item("b", ["a", "gone"], :ready)])
    assert [%{from: "a", to: "b", status: :done}] = layout.edges
    assert %{"b" => {1, 0}} = placed(layout)
  end

  test "an empty plan has no size" do
    assert %{nodes: [], edges: [], width: 0, height: 0} = PlanGraph.layout([])
  end
end
