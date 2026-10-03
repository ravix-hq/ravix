defmodule Ravix.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.

  None of these starts the application. `bin/ravix eval` runs a node of its
  own (`nonode@nohost`) beside production, and the whole application there
  would start a second copy of every `Ravix.Cluster.Singleton` -- schedules,
  sandbox and preview reconcilers, tooling tasks -- that sees no cluster and
  so defers to nobody, plus an endpoint. `migrate/0` and `rollback/2` start
  only the Repo, through `Ecto.Migrator.with_repo/2`; every other task calls
  `start_services/0`, which starts `:ravix`'s dependencies and
  `Ravix.Application.services/0` and nothing else. The `mix ravix.*` tasks
  that reach a context do the same.
  """
  alias Ravix.People.Cutover
  alias Ravix.Projects.Consolidation
  alias Ravix.Tracks.{Billing, TitleBackfill}
  alias Ravix.Workspaces.{Backfill, PersonalAssignment, RaviSeed}

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
    start_services()

    case RaviSeed.run(apply: apply?) do
      {:ok, summary} ->
        Enum.each(RaviSeed.format(summary), &IO.puts/1)

      {:error, reason} ->
        raise "Seed refused: " <> RaviSeed.describe_error(reason)
    end
  end

  @doc """
  Put every legacy project into its owner's personal workspace
  (`Ravix.Workspaces.PersonalAssignment`), for a release with no Mix: a dry
  run unless `apply?`. Prints its summary, no secrets, and returns it.

  Starts the `Ravix.Repo` and nothing else, so it can run as a one-off job
  beside the serving release without a second copy of its singletons,
  endpoint or queue:

      bin/ravix eval "Ravix.Release.assign_personal_workspaces(false)"
  """
  def assign_personal_workspaces(apply? \\ false) do
    load_app()
    summary = with_repo_only(fn -> PersonalAssignment.run(apply: apply?) end)
    Enum.each(PersonalAssignment.format(summary), &IO.puts/1)
    summary
  end

  @doc "Consolidate one workspace after stopping serving instances; dry run by default."
  def consolidate_projects(workspace_id, apply? \\ false) do
    load_app()
    with_repo_only(fn -> Consolidation.run(workspace_id, apply: apply?) end)
  end

  @doc """
  Title the open tracks still called by their branch
  (`Ravix.Tracks.TitleBackfill`), for a release with no Mix: a dry run
  unless `apply?`. Prints its summary, ids only, and returns it. Starts the
  `Ravix.Repo` and nothing else:

      bin/ravix eval "Ravix.Release.retitle_tracks(true)"
  """
  def retitle_tracks(apply? \\ false) do
    load_app()
    summary = with_repo_only(fn -> TitleBackfill.run(apply: apply?) end)
    Enum.each(TitleBackfill.format(summary), &IO.puts/1)
    summary
  end

  @doc false
  # A data step's repository, without the application: `Ecto.Migrator.with_repo/2`
  # starts the repo alone (or uses the one already running) and stops what it started.
  def with_repo_only(fun) do
    {:ok, {:ok, result}, _apps} =
      Ecto.Migrator.with_repo(Ravix.Repo, fn _repo -> fun.() end)

    result
  end

  @doc """
  The invite-link cutover (`Ravix.People.Cutover`), for a release with no
  Mix: a dry run unless `apply?`. Prints its summary, no secrets.
  """
  def sharing_cutover(apply? \\ false) do
    start_services()

    case Cutover.run(apply: apply?) do
      {:ok, summary} -> Enum.each(Cutover.format(summary), &IO.puts/1)
      {:error, :switch_off} -> raise "Cutover refused: RAVIX_WORKSPACE_ACCESS is off."
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
    start_services()
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
    start_services()
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

  @doc """
  Start what a one-off task needs to call a context: the dependencies of
  `:ravix` (Ecto, Finch for Req, PubSub's registry) and
  `Ravix.Application.services/0` under a supervisor linked to the caller.
  The application itself, and with it every singleton, the endpoint and the
  prompt queue, is not started.

  A no-op where the application is already running -- `bin/ravix rpc` into
  a serving node, or the test suite -- since everything is there already,
  and where an earlier task in the same `eval` already started the services:
  the supervisor is named, so a second call finds it rather than starting a
  second `Ravix.Repo`.
  """
  @spec start_services() :: :ok
  def start_services do
    if List.keymember?(Application.started_applications(), @app, 0) do
      :ok
    else
      load_app()
      {:ok, _} = Application.ensure_all_started(Application.spec(@app, :applications))

      case Supervisor.start_link(Ravix.Application.services(),
             strategy: :one_for_one,
             name: Ravix.Release.Services
           ) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
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
