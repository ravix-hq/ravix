defmodule Ravix.Coverage do
  @moduledoc "Production-only coverage with separate server and UI floors."

  alias Mix.Tasks.Test.Coverage

  def start(compile_path, opts) do
    modules = production_modules(compile_path)
    ignored = Keyword.fetch!(opts, :ignore_modules)
    measured = Enum.reject(modules, fn {module, _} -> module in ignored end)
    all = Path.wildcard(Path.join(compile_path, "*.beam")) |> Enum.map(&beam_module/1)
    excluded = all -- Enum.map(measured, &elem(&1, 0))

    native =
      Coverage.start(compile_path, Keyword.put(opts, :ignore_modules, excluded))

    fn ->
      native.()
      rows = Enum.map(measured, &measure/1)
      floors = opts |> Keyword.fetch!(:groups) |> Map.new()
      groups = Enum.map(floors, fn {group, floor} -> summarize(group, rows, floor) end)
      report = %{modules: rows, groups: groups}
      File.write!("cover/quality.json", Jason.encode!(report, pretty: true))

      for group <- groups do
        Mix.shell().info("#{group.name}: #{group.percent}% (floor #{group.floor}%)")
      end

      enforce(groups)
    end
  end

  defp enforce(groups) do
    if Enum.any?(groups, &(&1.total == 0 or &1.covered * 100 < &1.floor * &1.total)) do
      Mix.shell().error("Coverage group floor not met. See cover/quality.json.")
      System.at_exit(fn _ -> exit({:shutdown, 3}) end)
    end
  end

  def line_counts(lines) do
    lines
    |> Enum.reject(fn {{_, line}, _} -> line == 0 end)
    |> Enum.reduce(%{}, fn {{_, line}, {covered, _}}, acc ->
      Map.update(acc, line, covered > 0, &(&1 or covered > 0))
    end)
    |> Enum.reduce({0, 0}, fn {_, hit}, {covered, total} ->
      {covered + if(hit, do: 1, else: 0), total + 1}
    end)
  end

  defp production_modules(path) do
    for beam <- Path.wildcard(Path.join(path, "*.beam")),
        {:ok, {module, [{:compile_info, info}]}} =
          :beam_lib.chunks(String.to_charlist(beam), [:compile_info]),
        source = info |> Keyword.fetch!(:source) |> to_string() |> Path.relative_to_cwd(),
        String.starts_with?(source, "lib/"),
        do: {module, source}
  end

  defp beam_module(path) do
    {:ok, {module, _}} = :beam_lib.chunks(String.to_charlist(path), [])
    module
  end

  defp measure({module, source}) do
    {:ok, lines} = :cover.analyse(module, :coverage, :line)
    {covered, total} = line_counts(lines)

    %{
      module: inspect(module),
      source: source,
      covered: covered,
      total: total,
      percent: percent(covered, total)
    }
  end

  defp summarize(group, rows, floor) do
    selected = Enum.filter(rows, &in_group?(&1, group))
    covered = Enum.sum(Enum.map(selected, & &1.covered))
    total = Enum.sum(Enum.map(selected, & &1.total))
    %{name: group, floor: floor, covered: covered, total: total, percent: percent(covered, total)}
  end

  defp in_group?(row, :server), do: String.starts_with?(row.source, "lib/ravix/")
  defp in_group?(row, :web), do: String.starts_with?(row.source, "lib/ravix_web/")
  # The workspace page and the dialogs only it opens. `SettingsDialog` is
  # named here because it was `WorkspaceLive` until the four forms in it
  # moved out, and a refactor must not quietly move behaviour from the 95%
  # floor to the 92% one. `PeopleDialog` is not: the track page opens it too,
  # so it belongs to `web` where both its callers are counted.
  defp in_group?(row, :workspace),
    do: row.module in ["RavixWeb.WorkspaceLive", "RavixWeb.Live.SettingsDialog"]

  defp in_group?(row, :track), do: row.module == "RavixWeb.TrackLive"
  defp percent(_, 0), do: 100.0
  defp percent(covered, total), do: Float.round(covered * 100 / total, 2)
end
