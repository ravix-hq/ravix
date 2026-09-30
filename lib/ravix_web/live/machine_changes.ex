defmodule RavixWeb.Live.MachineChanges do
  @moduledoc """
  What a project's Machine settings page is about to change (RAV-74).

  The page collects the setup script, the packages, the readable variables,
  the secrets and the run script behind one "Save & rebuild", and says
  first what that save changes. This is the comparison: the form's params
  against what is saved, answered as a `t:plan/0` of what to write and the
  lines that describe it.

  It is pure, and the lines never carry a value: "+jq in apt", "setup
  script edited", "1 secret added". Variables and secrets are counted, and
  what they are set to stays in the form. A plan holds secret
  values while it is being carried out, so the page builds one inside the
  task that writes it and keeps only its `lines` in assigns.
  """

  alias Ravix.Projects.EnvironmentVariables
  alias Ravix.Projects.EnvironmentVariables.Row

  @packages ~w(apt pip npm)
  @run_fields ~w(directory command readiness_path stop_command)

  @typedoc """
  One pending secret change: set a value, or remove the key. `existing`
  says whether the key is already there, so setting it replaces it.
  """
  @type secret :: %{
          required(:store) => String.t(),
          required(:key) => String.t(),
          required(:action) => :set | :remove,
          required(:value) => String.t() | nil,
          optional(:existing) => boolean()
        }

  @typedoc """
  What one save writes. `environment` is the `Ravix.Projects.update_settings/3`
  change for the environment (nil when it is untouched); `run` is `:keep`,
  nil to clear the run script, or the fields to save. `rebuild?` is whether
  the save needs a new machine: anything but the run script does, because
  the machine is built from the environment and its secrets.
  """
  @type plan :: %{
          environment: map() | nil,
          secrets: [secret()],
          run: :keep | nil | map(),
          rebuild?: boolean(),
          lines: [String.t()]
        }

  @doc "The package managers the page has a box for, in order."
  @spec managers() :: [String.t()]
  def managers, do: @packages

  @doc "The run script's fields, as the form names them."
  @spec run_fields() :: [String.t()]
  def run_fields, do: @run_fields

  @doc """
  The run script's form values for a saved default, or for none.
  """
  @spec run_params(map() | nil) :: %{String.t() => String.t()}
  def run_params(defaults) do
    config = defaults || %{}

    %{
      "directory" => Map.get(config, :directory) || ".",
      "command" => Map.get(config, :command) || "",
      "readiness_path" => Map.get(config, :readiness_path) || "",
      "stop_command" => Map.get(config, :stop_command) || ""
    }
  end

  @doc """
  The environment's form values for saved settings: the setup script, and
  each package list as one space-separated line.
  """
  @spec environment_params(map()) :: %{String.t() => String.t()}
  def environment_params(settings) do
    packages = settings.packages || %{}

    @packages
    |> Map.new(&{&1, Enum.join(packages[&1] || [], " ")})
    |> Map.put("setup_script", settings.setup_script || "")
  end

  @doc "A package line split into names, as `Ravix.Projects.Settings` stores them."
  @spec split_packages(String.t() | nil) :: [String.t()]
  def split_packages(line), do: String.split(line || "", ~r/[\s,]+/, trim: true)

  @doc """
  Compare the page's params with what is saved.

    * `settings` is `Ravix.Projects.Settings` as last read;
    * `defaults` the project's saved run script (nil for none);
    * `environment` the `settings` form params (setup script and packages);
    * `rows` the readable variables, as `Row`s in the order shown;
    * `secrets` the pending secret changes, in order;
    * `run` the `preview_defaults` form params.

  Refuses what cannot be saved at all, before anything is written: a
  variable list `EnvironmentVariables` would not take, a secret with no
  name, or one being set with no value.
  """
  @spec plan(map(), map() | nil, map(), [Row.t()], [secret()], map()) ::
          {:ok, plan()} | {:error, {:unprocessable, String.t(), String.t()}}
  def plan(settings, defaults, environment, rows, secrets, run) do
    with {:ok, vars} <- EnvironmentVariables.normalize(rows),
         :ok <- validate_secrets(secrets) do
      {env_attrs, env_lines} = environment(settings, environment, vars)
      {run_value, run_lines} = run_script(defaults, run)

      {:ok,
       %{
         environment: env_attrs,
         secrets: secrets,
         run: run_value,
         rebuild?: env_attrs != nil or secrets != [],
         lines: env_lines ++ secret_lines(secrets) ++ run_lines
       }}
    end
  end

  defp environment(settings, params, vars) do
    saved = environment_params(settings)
    script = Map.get(params, "setup_script", saved["setup_script"])
    script_changed? = script != saved["setup_script"]

    package_lines =
      for manager <- @packages,
          line = package_line(manager, saved[manager], Map.get(params, manager, saved[manager])),
          line != nil,
          do: line

    saved_vars = settings.env_vars || %{}
    var_lines = variable_lines(saved_vars, vars)

    attrs =
      %{}
      |> put_when(script_changed?, "setup_script", script)
      |> put_when(package_lines != [], "packages", packages(params, saved))
      |> put_when(var_lines != [], "env_vars", vars)
      |> put_when(var_lines != [], "expected_env_vars", saved_vars)

    lines =
      package_lines ++ if(script_changed?, do: ["setup script edited"], else: []) ++ var_lines

    {if(attrs == %{}, do: nil, else: attrs), lines}
  end

  defp packages(params, saved),
    do: Map.new(@packages, &{&1, split_packages(Map.get(params, &1, saved[&1]))})

  defp package_line(manager, saved, wanted) do
    before = split_packages(saved)
    now = split_packages(wanted)
    added = Enum.uniq(now -- before)
    removed = Enum.uniq(before -- now)

    changes = Enum.map(added, &"+#{&1}") ++ Enum.map(removed, &"−#{&1}")

    if changes == [], do: nil, else: "#{Enum.join(changes, " ")} in #{manager}"
  end

  # Counted, not named: "1 variable added". The names are on the page
  # above the question, and the values are nobody's business in a summary.
  defp variable_lines(saved, wanted) do
    changes =
      (Map.keys(saved) ++ Map.keys(wanted))
      |> Enum.uniq()
      |> Enum.map(&variable_change(Map.fetch(saved, &1), Map.fetch(wanted, &1)))
      |> Enum.frequencies()

    for verb <- ~w(added changed removed),
        n = Map.get(changes, verb, 0),
        n > 0,
        do: counted(n, "variable", verb)
  end

  defp variable_change(:error, {:ok, _}), do: "added"
  defp variable_change({:ok, _}, :error), do: "removed"
  defp variable_change({:ok, same}, {:ok, same}), do: nil
  defp variable_change({:ok, _}, {:ok, _}), do: "changed"

  defp secret_lines(secrets) do
    changes = Enum.frequencies_by(secrets, &secret_change/1)

    for verb <- ~w(added replaced removed),
        n = Map.get(changes, verb, 0),
        n > 0,
        do: counted(n, "secret", verb)
  end

  defp secret_change(%{action: :remove}), do: "removed"
  defp secret_change(%{existing: true}), do: "replaced"
  defp secret_change(_secret), do: "added"

  defp counted(1, noun, verb), do: "1 #{noun} #{verb}"
  defp counted(n, noun, verb), do: "#{n} #{noun}s #{verb}"

  defp validate_secrets(secrets) do
    cond do
      Enum.any?(secrets, &(String.trim(&1.key) == "")) ->
        {:error, {:unprocessable, "bad_key", "Name each secret, or remove its row."}}

      Enum.any?(secrets, &(&1.action == :set and &1.value in [nil, ""])) ->
        {:error, {:unprocessable, "no_secret_value", "Enter a value for each secret you set."}}

      duplicate_secret?(secrets) ->
        {:error,
         {:unprocessable, "duplicate_secret", "Change each secret once in a save: one row a key."}}

      true ->
        :ok
    end
  end

  defp duplicate_secret?(secrets) do
    keys = Enum.map(secrets, &{&1.store, String.trim(&1.key)})
    length(keys) != length(Enum.uniq(keys))
  end

  @doc "A secret store's label."
  @spec store_label(String.t()) :: String.t()
  def store_label("vault"), do: "Vault"
  def store_label(_env), do: "Environment"

  defp run_script(defaults, params) do
    saved = run_params(defaults)
    wanted = Map.merge(saved, Map.take(params || %{}, @run_fields))

    cond do
      wanted == saved -> {:keep, []}
      String.trim(wanted["command"]) == "" and defaults == nil -> {:keep, []}
      String.trim(wanted["command"]) == "" -> {nil, ["run script cleared"]}
      true -> {wanted, ["run script edited"]}
    end
  end

  defp put_when(map, true, key, value), do: Map.put(map, key, value)
  defp put_when(map, false, _key, _value), do: map
end
