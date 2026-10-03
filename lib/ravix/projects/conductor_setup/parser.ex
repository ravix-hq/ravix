defmodule Ravix.Projects.ConductorSetup.Parser do
  @moduledoc """
  Bounded, side-effect-free interpretation of shared Conductor repository setup.

  TOML owns run scripts when present. Cloud's legacy setup-only fallback is
  retained when TOML omits setup. A malformed file is refused, never hidden by
  a lower-precedence file. File patterns are suggestions, never resolved.
  """

  alias Ravix.Previews.Config

  @toml ".conductor/settings.toml"
  @json "conductor.json"
  @include ".worktreeinclude"
  @max_bytes 65_536
  @max_scripts 32

  @doc "The only repository files discovery reads."
  def paths, do: [@toml, @json, @include]

  @doc "The maximum decoded size of each repository file."
  def max_bytes, do: @max_bytes

  @doc "Parse discovered file contents (nil means absent)."
  @spec parse(map()) :: {:ok, map()} | {:error, term()}
  def parse(files) do
    with :ok <- bounded(files),
         {:ok, toml} <- decode(files[@toml], :toml),
         {:ok, json} <- legacy(files, toml),
         {:ok, report} <- report(toml, json, files[@include]) do
      {:ok, Map.put(report, :sources, Enum.filter(paths(), &is_binary(files[&1])))}
    end
  end

  defp bounded(files) do
    if Enum.all?(paths(), fn path ->
         case files[path] do
           nil -> true
           text when is_binary(text) -> byte_size(text) <= @max_bytes and String.valid?(text)
           _ -> false
         end
       end),
       do: :ok,
       else: invalid("Files must be UTF-8 text of at most 64 KiB each.")
  end

  defp decode(nil, _format), do: {:ok, nil}

  defp decode(text, format) do
    result = if format == :toml, do: TomlElixir.decode(text), else: Jason.decode(text)

    case result do
      {:ok, %{} = value} -> {:ok, value}
      _ -> invalid("The #{format} setup file is invalid.")
    end
  end

  # TOML outranks JSON except for Conductor cloud's setup-only fallback.
  defp legacy(files, %{"scripts" => %{"setup" => _}}), do: ignored_legacy(files)
  defp legacy(files, nil), do: decode(files[@json], :json)
  defp legacy(files, _toml), do: decode(files[@json], :json)
  defp ignored_legacy(_files), do: {:ok, nil}

  defp report(toml, json, include) do
    settings = toml || json || %{}
    scripts = settings["scripts"] || %{}
    legacy_scripts = (json || %{})["scripts"] || %{}

    with true <- is_map(scripts) and is_map(legacy_scripts),
         {:ok, setup} <- setup(scripts, legacy_scripts),
         {:ok, runs} <- runs(scripts["run"]),
         {:ok, patterns} <- patterns(include, settings["file_include_globs"]) do
      {:ok,
       %{
         setup: setup,
         runs: runs,
         patterns: patterns,
         pattern_source: if(include != nil, do: @include, else: "file_include_globs / default"),
         warnings: warnings(settings, scripts, toml, json)
       }}
    else
      false -> invalid("Scripts must be an object/table.")
      error -> error
    end
  end

  defp setup(scripts, legacy) do
    case Map.get(scripts, "setup", legacy["setup"]) do
      nil -> {:ok, nil}
      command -> candidate("setup", %{"command" => command}, 20_000)
    end
  end

  defp runs(nil), do: {:ok, []}
  defp runs(command) when is_binary(command), do: runs(%{"run" => %{"command" => command}})

  defp runs(scripts) when is_map(scripts) and map_size(scripts) <= @max_scripts do
    scripts
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {id, attrs}, {:ok, acc} ->
      case candidate(id, attrs, 8_000) do
        {:ok, script} -> {:cont, {:ok, acc ++ [script]}}
        error -> {:halt, error}
      end
    end)
  end

  defp runs(_), do: invalid("Supply at most 32 named run scripts or a single command.")

  defp candidate(id, attrs, limit) when is_binary(id) and is_map(attrs) do
    command = attrs["command"]
    args = Map.get(attrs, "args", [])
    options = Map.get(attrs, "options", %{})
    available = Map.get(attrs, "available_in", ["local", "cloud"])
    available = if is_binary(available), do: [available], else: available

    with true <- valid_text?(id, 200) and valid_text?(command, limit),
         true <- is_list(args) and Enum.all?(args, &valid_text?(&1, 1_000)),
         true <- is_map(options),
         true <- is_list(available) and Enum.all?(available, &(&1 in ["local", "cloud"])),
         true <- is_boolean(Map.get(attrs, "default", false)) do
      command = Enum.join([command | Enum.map(args, &shell_quote/1)], " ")
      directory = Map.get(options, "cwd", ".")
      issues = candidate_issues(command, directory, available, limit)

      {:ok,
       %{
         id: id,
         command: command,
         directory: directory,
         default?: attrs["default"] == true,
         cloud?: "cloud" in available,
         selectable?: issues == [],
         issues: issues
       }}
    else
      _ -> invalid("A script has invalid command, arguments, availability, default or options.")
    end
  end

  defp candidate(_, _, _), do: invalid("Each named run script must be an object/table.")

  defp candidate_issues(command, directory, available, limit) do
    []
    |> issue("cloud" not in available, "This script is local-only.")
    |> issue(
      String.contains?(command, "CONDUCTOR_"),
      "Conductor variables are unavailable here. Edit the command for cloud use; run servers must honor $PORT, bind to 127.0.0.1 and refuse port fallback."
    )
    |> issue(byte_size(command) > limit, "The command and arguments exceed Ravix's limit.")
    |> issue(
      not valid_directory?(directory),
      "Review the working directory; Ravix requires a relative path inside the track."
    )
  end

  defp valid_directory?(directory),
    do: match?({:ok, _}, Config.parse(%{directory: directory, command: "review"}))

  defp valid_text?(text, limit),
    do: is_binary(text) and byte_size(text) in 1..limit and not String.contains?(text, <<0>>)

  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  defp patterns(include, globs) do
    text = if include != nil, do: include, else: globs || ".env*"

    if is_binary(text) do
      patterns = text |> String.split("\n") |> Enum.map(&String.trim/1)
      patterns = Enum.reject(patterns, &(&1 == "" or String.starts_with?(&1, "#")))

      if length(patterns) <= 100 and Enum.all?(patterns, &valid_text?(&1, 1_000)),
        do: {:ok, patterns},
        else: invalid("Supply at most 100 file patterns of at most 1,000 bytes each.")
    else
      invalid("File include globs must be text.")
    end
  end

  defp warnings(settings, scripts, toml, json) do
    []
    |> issue(
      scripts["archive"] != nil,
      "Archive scripts cannot map to Ravix and will not be imported."
    )
    |> issue(
      scripts["run_mode"] != nil or settings["runScriptMode"] != nil,
      "Run mode cannot map to Ravix. Tracks run independently; review shared ports, databases and other resources."
    )
    |> issue(scripts["auto_run_after_setup"] != nil, "Automatic run after setup is not imported.")
    |> issue(
      settings["spotlight_testing"] == true,
      "Spotlight testing requires a local repository root and is unsupported in cloud tracks."
    )
    |> issue(
      settings["environment_variables"] != nil,
      "Repository environment values are not imported. Provision required variables and secrets explicitly in Machine settings."
    )
    |> issue(
      toml != nil and json != nil,
      "TOML takes precedence; only a missing setup script falls back to legacy JSON for cloud compatibility."
    )
  end

  defp issue(issues, true, message), do: issues ++ [message]
  defp issue(issues, false, _message), do: issues

  @doc "Stage only explicitly selected candidates into the existing settings forms."
  @spec select(map(), map()) :: {:ok, map()} | {:error, term()}
  def select(report, params) do
    with {:ok, setup} <- selected_setup(report, params["setup"]),
         {:ok, run} <- selected_run(report, params["run"]) do
      {:ok, %{setup: setup, run: run}}
    end
  end

  defp selected_setup(_report, value) when value in [nil, "", "false"], do: {:ok, nil}
  defp selected_setup(%{setup: %{selectable?: true} = script}, "true"), do: {:ok, script.command}
  defp selected_setup(_, _), do: invalid("Choose a cloud-compatible setup script.")

  defp selected_run(_report, value) when value in [nil, ""], do: {:ok, nil}

  defp selected_run(report, id) do
    case Enum.find(report.runs, &(&1.id == id and &1.selectable?)) do
      nil -> invalid("Choose a cloud-compatible run script.")
      script -> {:ok, %{"command" => script.command, "directory" => script.directory}}
    end
  end

  defp invalid(message), do: {:error, {:unprocessable, "conductor_setup", message}}
end
