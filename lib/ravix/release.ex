defmodule Ravix.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  alias Ravix.Tracks.Billing
  alias Ravix.Workspaces.{Backfill, RaviSeed}

  @app :ravix

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ravix.Repo.prepare_schema(repo)
          Ecto.Migrator.run(repo, :up, all: true, prefix: "ravix")
          # Idempotent and resumable; reconciles what the previous release wrote.
          Backfill.run()
        end)
    end
  end

  @doc """
  The Ravi workspace seed (`Ravix.Workspaces.RaviSeed`), for a release with
  no Mix: a dry run unless `apply?`. Prints its summary, no secrets.
  """
  def seed_ravi_workspace(apply? \\ false) do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)

    case RaviSeed.run(apply: apply?) do
      {:ok, summary} ->
        Enum.each(RaviSeed.format(summary), &IO.puts/1)

      {:error, reason} ->
        raise "Seed refused: " <> RaviSeed.describe_error(reason)
    end
  end

  def rollback(repo, version) do
    load_app()

    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version, prefix: "ravix"))
  end

  @doc """
  The creator-billing activation check (`mix ravix.provider_secrets`), for a
  release with no Mix: prints each project holding a provider-named variable
  or secret, by name only, and returns how many there were. Run it inside
  the serving node, which already has its database and Fountain client:

      bin/ravix rpc 'Ravix.Release.provider_secrets()'
  """
  def provider_secrets do
    lines = provider_secret_lines() ++ allowlist_lines()

    case lines do
      [] -> IO.puts("No project holds a provider-named variable or secret, and no agent is open.")
      lines -> Enum.each(lines, &IO.puts/1)
    end

    length(lines)
  end

  @doc """
  Close every agent allowlist Fountain reads as open (nil), idempotently,
  before turning on creator billing, and print what was done:

      bin/ravix rpc 'Ravix.Release.close_open_allowlists()'

  Returns how many agents are still open afterwards (0 when all closed).
  """
  def close_open_allowlists do
    lines = allowlist_lines(close: true)
    Enum.each(lines, &IO.puts/1)
    Enum.count(lines, &(not String.ends_with?(&1, ": closed")))
  end

  @doc false
  def allowlist_lines(opts \\ []) do
    Ravix.Fountain.client()
    |> Billing.open_allowlists(opts)
    |> Enum.map(fn finding ->
      "#{finding.project_id} agent #{finding.agent_id}: #{allowlist_state(finding.state)}"
    end)
  end

  defp allowlist_state(:open), do: "allowlist open (nil)"
  defp allowlist_state(:closed), do: "closed"
  defp allowlist_state(:already), do: "closed"
  defp allowlist_state({:error, reason}), do: "unreadable (#{inspect(reason)})"

  @doc false
  def provider_secret_lines do
    Ravix.Fountain.client()
    |> Billing.inventory()
    |> Enum.map(fn finding ->
      "#{finding.project_id} #{inspect(finding.name)}: environment #{describe(finding.environment)}; vault #{describe(finding.vault)}"
    end)
  end

  defp describe([]), do: "none"
  defp describe(names) when is_list(names), do: Enum.join(names, ", ")
  defp describe({:error, reason}), do: "unreadable (#{inspect(reason)})"

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
