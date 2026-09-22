defmodule Ravix.Credo.Architecture do
  @moduledoc "Enforce context direction, the row-layer boundary, and supervised work."
  use Credo.Check, id: "RVX001", base_priority: :high, category: :warning

  # Which context owns which table, where the directory does not say.
  #
  # A membership row is named after its subject and lives in that subject's
  # directory -- `Ravix.Tracks.TrackMember` under `tracks/` -- but the context
  # that reads and writes all seven of them is `Ravix.People`, because
  # membership is what People *is*. `tracks/track.ex` and `projects/project.ex`
  # name them only in `has_many`, which is a schema declaration and not a read.
  #
  # Anywhere else, the directory is the owner.
  @owners %{
    TrackMember: :People,
    TrackInvite: :People,
    TrackLink: :People,
    TrackRead: :People,
    ProjectMember: :People,
    ProjectInvite: :People,
    ProjectLink: :People
  }

  @spawn ~w(spawn spawn_link spawn_monitor spawn_opt)a
  @task ~w(start start_link async async_stream)a

  # The module names that take ids and establish nobody's access. A `Store`
  # holds a context's rows; a `Lifecycle` (`Ravix.Previews.Lifecycle`) drives
  # a context's processes by id -- start, stop, retire -- and is kept out of
  # the store because it is not row access. Neither asks who is calling, so
  # both are judged the same way below.
  @unscoped ~w(Store Lifecycle)a

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

      {_, findings} =
        Macro.prewalk(ast, findings, &stores(&1, &2, aliases, path, lines))

      {_, findings} =
        Macro.prewalk(ast, findings, &foreign_rows(&1, &2, aliases, path, lines))

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

  # `alias A.B.{C, D}` binds two names, and a rule that cannot see them is a
  # rule anybody can step around by grouping their aliases.
  defp aliases({:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, tails} | _]} = node, acc) do
    {node,
     Enum.reduce(tails, acc, fn
       {:__aliases__, _, parts}, acc -> Map.put(acc, List.last(parts), base ++ parts)
       _, acc -> acc
     end)}
  end

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

  # ── another context's rows, the short way round ──────────────────────
  #
  # The `Store` rule below is about module names, and `Repo` is not one of
  # them: a context calling `Repo.get(Track, id)` reaches another context's
  # rows with nothing to say so, while the same read through
  # `Tracks.Store.get_track/1` would have to explain itself. That left the
  # shorter path to write as the unchecked one, which is the wrong way round.
  #
  # So a `Repo` call that names a module belonging to another context wants
  # the same `# ownership:` comment. Naming one *outside* a `Repo` call is
  # untouched -- a schema's `belongs_to` crosses contexts by design, and so
  # does a supervisor listing children.

  defp foreign_rows(
         {{:., _, [{:__aliases__, _, parts}, fun]}, meta, args} = node,
         found,
         aliases,
         path,
         lines
       )
       when is_atom(fun) and is_list(args) do
    if resolve(parts, aliases) == [:Ravix, :Repo] and not ownership?(lines, meta[:line]) do
      {node, args |> foreign_in(aliases, path) |> Enum.reduce(found, &flag_foreign(&1, &2, meta))}
    else
      {node, found}
    end
  end

  defp foreign_rows(node, found, _aliases, _path, _lines), do: {node, found}

  # Every module named anywhere inside the call, including inside an
  # `Ecto.Query` expression or a transaction's function body.
  defp foreign_in(args, aliases, path) do
    mine = context_of(path)

    {_, named} =
      Macro.prewalk(args, [], fn
        {:__aliases__, _, parts} = n, acc -> {n, [resolve(parts, aliases) | acc]}
        n, acc -> {n, acc}
      end)

    named
    |> Enum.filter(&match?([:Ravix, _ctx, _mod | _], &1))
    |> Enum.reject(&(owner_of(&1) == mine))
    |> Enum.map(&Enum.join(Enum.map(&1, fn p -> Atom.to_string(p) end), "."))
    |> Enum.uniq()
  end

  # The declared owner if there is one, else the directory the module sits in.
  defp owner_of([:Ravix, ctx, mod | _]), do: Map.get(@owners, mod, ctx)

  defp flag_foreign(name, found, meta) do
    [
      {meta[:line],
       "This Repo call names #{name}, which belongs to another context. Read it through " <>
         "that context's Store, or add a nearby # ownership: comment saying which door " <>
         "this caller already went through."}
      | found
    ]
  end

  # ── the row layer ─────────────────────────────────────────────────────
  #
  # A `Ravix.<Context>.Store` takes ids and establishes nobody's access, and
  # so does a `Ravix.<Context>.Lifecycle` (see `@unscoped`). Two rules, and
  # the first has no exception: a page may not reach one. Pages have a user
  # in hand and `Ravix.Accounts.Access` to spend it at, so a page calling a
  # store is a page that decided not to ask.
  #
  # The second is for contexts, which legitimately hold ids they were let in
  # to. Reaching into *another* context's store is allowed and has to say so:
  # the `# ownership:` comment names the door the caller already went through.
  # Its own store needs no comment, because the module around it is the door.

  defp stores({:defdelegate, meta, [_fun, opts]} = node, found, aliases, path, lines)
       when is_list(opts) do
    case Keyword.get(opts, :to) do
      {:__aliases__, _, parts} -> {node, store_finding(parts, meta, found, aliases, path, lines)}
      _ -> {node, found}
    end
  end

  defp stores(
         {{:., _, [{:__aliases__, _, parts}, fun]}, meta, args} = node,
         found,
         aliases,
         path,
         lines
       )
       when is_atom(fun) and is_list(args) do
    {node, store_finding(parts, meta, found, aliases, path, lines)}
  end

  defp stores({:alias, meta, [{:__aliases__, _, parts} | _]} = node, found, aliases, path, lines) do
    # An alias is only worth flagging in the web layer, where naming a store at
    # all is the violation. A context aliasing one is judged at its call sites.
    if web?(path),
      do: {node, store_finding(parts, meta, found, aliases, path, lines)},
      else: {node, found}
  end

  defp stores(node, found, _aliases, _path, _lines), do: {node, found}

  defp store_finding(parts, meta, found, aliases, path, lines) do
    parts = resolve(parts, aliases)

    with true <- List.last(parts) in @unscoped,
         [:Ravix, context | _] <- parts do
      kind = List.last(parts)

      cond do
        web?(path) ->
          [
            {meta[:line],
             "The web layer must not reach a #{kind}, which takes ids and asks nobody; " <>
               "go through the context and `Ravix.Accounts.Access`."}
            | found
          ]

        context != context_of(path) and not ownership?(lines, meta[:line]) ->
          [
            {meta[:line],
             "Reaching another context's #{kind} needs a nearby # ownership: comment " <>
               "naming the door this caller already went through."}
            | found
          ]

        true ->
          found
      end
    else
      _ -> found
    end
  end

  defp resolve([first | rest], aliases),
    do: Enum.reject(Map.get(aliases, first, [first]) ++ rest, &(&1 == Elixir))

  defp web?(path), do: String.starts_with?(path, "lib/ravix_web/")

  # `lib/ravix/people/store.ex` and `lib/ravix/people.ex` are both People.
  defp context_of("lib/ravix/" <> rest) do
    rest
    |> String.split("/")
    |> List.first()
    |> Path.rootname()
    |> Macro.camelize()
    |> String.to_atom()
  end

  defp context_of(_), do: nil

  defp ownership?(lines, line) do
    Enum.any?(max(1, line - 6)..line, fn n ->
      Regex.match?(~r/^\s*#\s*ownership:\s*\S.+/i, Map.get(lines, n, ""))
    end)
  end
end
