defmodule Ravix.Credo.Architecture do
  @moduledoc "Enforce context direction, scoped unsafe calls, and supervised work."
  use Credo.Check, id: "RVX001", base_priority: :high, category: :warning

  @spawn ~w(spawn spawn_link spawn_monitor spawn_opt)a
  @task ~w(start start_link async async_stream)a

  @impl true
  def run(source, params) do
    path = Path.relative_to_cwd(source.filename)

    if String.starts_with?(path, "lib/") do
      meta = IssueMeta.for(source, params)
      lines = source |> Credo.SourceFile.lines() |> Map.new()
      ast = Credo.SourceFile.ast(source)
      {_, aliases} = Macro.prewalk(ast, %{}, &aliases/2)
      {_, findings} = Macro.prewalk(ast, [], &inspect_node(&1, &2, path, lines))
      {_, findings} = Macro.prewalk(ast, findings, &tasks(&1, &2, aliases))

      findings
      |> Enum.uniq()
      |> Enum.map(fn {line, message} -> format_issue(meta, line_no: line, message: message) end)
    else
      []
    end
  end

  defp inspect_node({:__aliases__, meta, parts} = node, found, path, _lines) do
    parts = Enum.reject(parts, &(&1 == Elixir))

    cond do
      List.first(parts) == :RavixWeb and String.starts_with?(path, "lib/ravix/") and
          path != "lib/ravix/application.ex" ->
        {node,
         [
           {meta[:line],
            "Contexts must not depend on RavixWeb; translate HTTP at the web boundary."}
           | found
         ]}

      true ->
        {node, found}
    end
  end

  defp inspect_node({{:., _, [_mod, fun]}, meta, args} = node, found, _path, lines)
       when is_atom(fun) and is_list(args) do
    cond do
      String.starts_with?(Atom.to_string(fun), "_unsafe_") and not ownership?(lines, meta[:line]) ->
        {node,
         [
           {meta[:line],
            "Remote _unsafe_ call needs a nearby # ownership: comment naming its scoped fetch or internal owner."}
           | found
         ]}

      true ->
        {node, found}
    end
  end

  defp inspect_node({fun, meta, args} = node, found, _path, _lines)
       when fun in @spawn and is_list(args),
       do:
         {node,
          [{meta[:line], "Use the application TaskSupervisor for background work."} | found]}

  defp inspect_node(node, found, _path, _lines), do: {node, found}

  defp aliases({:alias, _, [{:__aliases__, _, parts} | opts]} = node, acc) do
    name = opts |> List.first() |> Kernel.||([]) |> Keyword.get(:as)

    key =
      case name do
        {:__aliases__, _, [as]} -> as
        _ -> List.last(parts)
      end

    {node, Map.put(acc, key, parts)}
  end

  defp aliases(node, acc), do: {node, acc}

  defp tasks({{:., _, [mod, fun]}, meta, args} = node, found, aliases)
       when is_atom(fun) and is_list(args) do
    parts =
      case mod do
        {:__aliases__, _, [first | rest]} -> Map.get(aliases, first, [first]) ++ rest
        :erlang -> [:erlang]
        _ -> []
      end

    parts = Enum.reject(parts, &(&1 == Elixir))

    if (parts == [:Task] and fun in @task) or (parts in [[:Kernel], [:erlang]] and fun in @spawn) do
      {node,
       [
         {meta[:line],
          "Use Task.Supervisor or LiveView start_async for owned work; await supervised tasks when a result is needed."}
         | found
       ]}
    else
      {node, found}
    end
  end

  defp tasks({:import, meta, [{:__aliases__, _, [:Task]} | _]} = node, found, _aliases),
    do: {node, [{meta[:line], "Do not import Task; call supervised work explicitly."} | found]}

  defp tasks(node, found, _aliases), do: {node, found}

  defp ownership?(lines, line) do
    Enum.any?(max(1, line - 6)..line, fn n ->
      Regex.match?(~r/^\s*#\s*ownership:\s*\S.+/i, Map.get(lines, n, ""))
    end)
  end
end
