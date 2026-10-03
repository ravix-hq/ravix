defmodule Ravix.Tooling.PreviewTools do
  @moduledoc "Scoped preview operations. No OAuth operation mints a browser access grant."

  alias Ravix.Accounts.Access
  alias Ravix.Previews
  alias Ravix.Tooling.Mutations

  @reads ~w(get_preview_config preview_status preview_logs)
  @project_tools ~w(get_preview_defaults update_preview_defaults)

  def execute(p, "get_preview_config", a) do
    with {:ok, view} <- Previews.status(p.user, a["track_id"]),
         do: {:ok, configuration(view)}
  end

  def execute(p, "preview_status", a), do: present(Previews.status(p.user, a["track_id"]))

  def execute(p, "preview_logs", a),
    do: present(Previews.logs(p.user, a["track_id"]), Map.get(a, "limit", 4000))

  def execute(p, "get_preview_defaults", a),
    do: defaults(Previews.defaults(p.user, a["project_id"]))

  def execute(p, name, a) do
    with :ok <- access(p, name, a),
         :ok <- validate_configuration(name, a) do
      Mutations.run(p, name, a, fn -> mutate(p, name, a) end)
    end
  end

  def recheck(p, name, a, _result), do: access(p, name, a)

  defp access(p, name, a) when name in @project_tools,
    do: access_result(Access.project_of(p.user, a["project_id"]))

  defp access(p, name, a) do
    need = if name in @reads, do: :read, else: :write
    access_result(Access.track_access(p.user, a["track_id"], need))
  end

  defp access_result({:ok, _}), do: :ok
  defp access_result(error), do: error

  defp validate_configuration(name, a)
       when name in ["update_preview_config", "update_preview_defaults"] do
    if (Map.has_key?(a, "config") and a["reset"] != true) or
         (a["reset"] == true and not Map.has_key?(a, "config")) do
      :ok
    else
      {:error,
       {:unprocessable, "invalid_arguments", "Supply config or reset: true, exclusively."}}
    end
  end

  defp validate_configuration(_, _), do: :ok

  defp mutate(p, "update_preview_config", a),
    do: present(Previews.save_config(p.user, a["track_id"], a["config"]))

  defp mutate(p, "update_preview_defaults", a),
    do: defaults(Previews.set_defaults(p.user, a["project_id"], a["config"]))

  defp mutate(p, "stop_preview", a), do: present(Previews.stop(p.user, a["track_id"]))

  defp mutate(p, name, a) when name in ["run_preview", "start_preview", "restart_preview"] do
    mode = if name == "restart_preview", do: :restart, else: :start
    present(Previews.run(p.user, a["track_id"], mode))
  end

  defp defaults({:ok, config}), do: {:ok, %{config: config_map(config)}}
  defp defaults(error), do: error

  defp configuration(view),
    do: %{config: config_map(view.config), override: config_map(view.override)}

  defp config_map(nil), do: nil

  defp config_map(config),
    do: Map.take(config, [:directory, :command, :stop_command, :readiness_path])

  # Explicit selection keeps open_url (a browser ticket) and provider identity
  # out of both responses and durable mutation receipts.
  defp present(result, limit \\ 4000)

  defp present({:ok, view}, limit) do
    # Codepoints, rather than graphemes: combining characters must not turn
    # the advertised 4000-character cap into an unbounded byte payload.
    logs = String.codepoints(view.logs || "")

    {:ok,
     view
     |> Map.take([:state, :available, :unavailable_reason, :keeps_awake, :error, :url])
     |> Map.merge(configuration(view))
     |> Map.put(:logs, logs |> Enum.take(-limit) |> Enum.join())
     |> Map.put(:logs_truncated, length(logs) > limit)}
  end

  defp present(error, _limit), do: error
end
