defmodule Ravix.Plans.Graph do
  @moduledoc "Bounded same-plan dependency validation, independent of row access."
  def validate(items) do
    graph = Map.new(items, &{&1.id, &1.dependencies})

    cond do
      map_size(graph) != length(items) ->
        invalid("Item IDs must be unique.")

      Enum.any?(items, fn i -> Enum.any?(i.dependencies, &(not Map.has_key?(graph, &1))) end) ->
        invalid("Dependencies must name items in this plan.")

      Enum.any?(Map.keys(graph), &cycle?(graph, &1, [])) ->
        invalid("Dependencies must not contain a cycle.")

      true ->
        :ok
    end
  end

  defp cycle?(graph, id, path) do
    visit(graph, id, path, []) == :cycle
  end

  defp visit(graph, id, path, done) do
    cond do
      id in path ->
        :cycle

      id in done ->
        done

      true ->
        visit_children(graph, id, path, done)
    end
  end

  defp visit_children(graph, id, path, done) do
    Enum.reduce_while(graph[id], [id | done], fn child, seen ->
      case visit(graph, child, [id | path], seen) do
        :cycle -> {:halt, :cycle}
        visited -> {:cont, visited}
      end
    end)
  end

  defp invalid(message), do: {:error, {:unprocessable, "invalid_dependencies", message}}
end
