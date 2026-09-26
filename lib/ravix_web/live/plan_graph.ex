defmodule RavixWeb.Live.PlanGraph do
  @moduledoc """
  A plan's dependency graph, drawn on the server so it needs no browser hook.

  An item's column is the length of its longest dependency chain, so every
  edge points right. Within a column, items sit near the rows of what they
  depend on and otherwise keep the plan's order. `Ravix.Plans.Graph` has
  already refused cycles and dangling ids; anything else is ignored here.
  """
  use RavixWeb, :html

  @node_width 184
  @node_height 68
  @column_gap 44
  @row_gap 14

  attr :items, :list, required: true

  def graph(assigns) do
    assigns = assign(assigns, :layout, layout(assigns.items))

    ~H"""
    <details :if={@items != []} class="plan-graph" open>
      <summary>Dependency graph</summary>
      <div class="plan-graph-scroll">
        <div
          class="plan-graph-canvas"
          style={"width: #{@layout.width}px; height: #{@layout.height}px"}
        >
          <svg
            width={@layout.width}
            height={@layout.height}
            viewBox={"0 0 #{@layout.width} #{@layout.height}"}
            aria-hidden="true"
            focusable="false"
          >
            <path
              :for={edge <- @layout.edges}
              class={"plan-graph-edge plan-graph-edge-#{edge.status}"}
              d={edge.path}
            />
          </svg>
          <ol class="plan-graph-nodes">
            <li
              :for={node <- @layout.nodes}
              class={"plan-graph-node plan-graph-#{node.item.status}"}
              style={"left: #{node.x}px; top: #{node.y}px; width: #{@layout.node_width}px; height: #{@layout.node_height}px"}
            >
              <a href={"#item-#{node.item.id}"} title={node.item.title}>
                <span class="plan-graph-title">{node.item.title}</span>
                <span class="plan-graph-status">{status_label(node.item.status)}</span>
              </a>
            </li>
          </ol>
        </div>
      </div>
    </details>
    """
  end

  @doc "Places items in columns by dependency depth and draws an edge per dependency."
  def layout(items) do
    ids = MapSet.new(items, & &1.id)
    deps = Map.new(items, &{&1.id, Enum.filter(&1.dependencies, fn d -> d in ids end)})
    columns = columns(items, deps)
    rows = rows(items, deps, columns)

    nodes =
      Enum.map(items, fn item ->
        %{
          item: item,
          column: columns[item.id],
          row: rows[item.id],
          x: x(columns[item.id]),
          y: y(rows[item.id])
        }
      end)

    at = Map.new(nodes, &{&1.item.id, &1})

    edges =
      for node <- nodes, dep <- deps[node.item.id] do
        from = at[dep]
        %{from: dep, to: node.item.id, status: from.item.status, path: curve(from, node)}
      end

    column_count = if nodes == [], do: 0, else: Enum.max(Enum.map(nodes, & &1.column)) + 1
    row_count = if nodes == [], do: 0, else: Enum.max(Enum.map(nodes, & &1.row)) + 1

    %{
      nodes: nodes,
      edges: edges,
      node_width: @node_width,
      node_height: @node_height,
      width: max(column_count * (@node_width + @column_gap) - @column_gap, 0),
      height: max(row_count * (@node_height + @row_gap) - @row_gap, 0)
    }
  end

  defp columns(items, deps) do
    Enum.reduce(items, %{}, fn item, memo -> depth(item.id, deps, memo) |> elem(1) end)
  end

  defp depth(id, deps, memo) do
    case memo do
      %{^id => column} ->
        {column, memo}

      _ ->
        {column, memo} =
          Enum.reduce(deps[id], {0, memo}, fn dep, {column, memo} ->
            {parent, memo} = depth(dep, deps, memo)
            {max(column, parent + 1), memo}
          end)

        {column, Map.put(memo, id, column)}
    end
  end

  # Columns fill left to right, so a dependency's row is known before its
  # dependents are sorted by the mean of those rows.
  defp rows(items, deps, columns) do
    order = items |> Enum.with_index() |> Map.new(fn {item, i} -> {item.id, i} end)

    items
    |> Enum.group_by(&columns[&1.id])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(%{}, fn {_, column}, rows ->
      column
      |> Enum.sort_by(&{mean_row(deps[&1.id], rows, order[&1.id]), order[&1.id]})
      |> Enum.with_index()
      |> Enum.reduce(rows, fn {item, row}, rows -> Map.put(rows, item.id, row) end)
    end)
  end

  defp mean_row([], _rows, position), do: position
  defp mean_row(deps, rows, _), do: Enum.sum(Enum.map(deps, &rows[&1])) / length(deps)

  defp x(column), do: column * (@node_width + @column_gap)
  defp y(row), do: row * (@node_height + @row_gap)

  defp curve(from, to) do
    {x1, y1} = {from.x + @node_width, from.y + div(@node_height, 2)}
    {x2, y2} = {to.x, to.y + div(@node_height, 2)}
    bend = div(x2 - x1, 2)
    "M#{x1},#{y1} C#{x1 + bend},#{y1} #{x2 - bend},#{y2} #{x2},#{y2}"
  end

  defp status_label(status), do: status |> to_string() |> String.replace("_", " ")
end
