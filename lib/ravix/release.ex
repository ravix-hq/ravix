defmodule Ravix.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
