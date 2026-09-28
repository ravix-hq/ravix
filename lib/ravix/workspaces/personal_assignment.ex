defmodule Ravix.Workspaces.PersonalAssignment do
  @moduledoc """
  The one-time data step that puts every legacy project into its owner's
  personal workspace (the owner's decision of 2026-09-28, following ADR
  0009).

  Each project with no workspace is considered, oldest first:

    * archived, deleting and marked legacy-duplicate projects are skipped
      and reported as such;
    * a project whose owner has no live personal workspace is left alone
      and reported (`Ravix.Workspaces.Backfill` creates them on every
      deploy, so this is an owner the backfill has not reached);
    * a project whose owner's personal workspace already holds a project
      for the same repository (compared as `Project.normalize_repo/1` does)
      is **not** moved: it is marked the legacy duplicate of that one and
      reported for the owner to decide, instead of guessed about. Two
      legacy projects of one owner and one repository are the same case:
      the older moves, the later is marked its duplicate;
    * everything else moves. Its legacy owner, members, tracks and grants
      stay as they are, so every legacy door still admits whoever it did.

  A dry run by default: `run(apply: false)` works out and returns the plan
  and writes nothing. `run(apply: true)` writes it, one project at a time,
  each write conditional on the row still being unassigned, so a run cut
  off halfway, or run again, picks up exactly what is left and a finished
  one changes nothing. The summary holds ids, names, logins and
  repositories, never a secret.

  Needs the `Ravix.Repo` and nothing else: `Ravix.Release.assign_personal_workspaces/1`
  runs it without starting the application, so no singleton or endpoint
  starts beside the serving release.

  An operator step, run as no user: every row it touches goes through
  `Ravix.Workspaces.Store`.
  """

  alias Ravix.Projects.Project
  alias Ravix.Workspaces.Store

  @type action ::
          :move | :duplicate | :no_workspace | :archived | :deleting | :legacy_duplicate
  @type line :: %{
          id: String.t(),
          name: String.t(),
          repo: String.t() | nil,
          owner: String.t() | nil,
          workspace_id: String.t() | nil,
          action: action(),
          duplicate_of: String.t() | nil
        }
  @type summary :: %{applied: boolean(), projects: [line()]}

  @doc "Work out the assignment, and write it when `apply: true`."
  @spec run(keyword()) :: {:ok, summary()}
  def run(opts \\ []) do
    lines = plan()

    if Keyword.get(opts, :apply, false) do
      Enum.each(lines, &write/1)
      {:ok, %{applied: true, projects: lines}}
    else
      {:ok, %{applied: false, projects: lines}}
    end
  end

  defp plan do
    rows = Store.unassigned_projects()

    holders =
      rows
      |> Enum.map(& &1.workspace_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Store.index_holders()

    {lines, _holders} = Enum.map_reduce(rows, holders, &line/2)
    lines
  end

  defp line(%{project: project, login: login, workspace_id: workspace_id}, holders) do
    base = %{
      id: project.id,
      name: project.name,
      repo: project.repo_full_name,
      owner: login,
      workspace_id: workspace_id,
      action: :move,
      duplicate_of: nil
    }

    key = {workspace_id, repo_key(project)}

    cond do
      project.legacy_duplicate_at -> {%{base | action: :legacy_duplicate}, holders}
      project.archived_at -> {%{base | action: :archived}, holders}
      project.deletion_requested_at -> {%{base | action: :deleting}, holders}
      is_nil(workspace_id) -> {%{base | action: :no_workspace}, holders}
      is_nil(elem(key, 1)) -> {base, holders}
      canonical = holders[key] -> {%{base | action: :duplicate, duplicate_of: canonical}, holders}
      true -> {base, Map.put(holders, key, project.id)}
    end
  end

  defp repo_key(%Project{} = project),
    do: project.normalized_repo_full_name || Project.normalize_repo(project.repo_full_name)

  defp write(%{action: :move, id: id, workspace_id: workspace_id}),
    do: Store.move_project(id, workspace_id)

  # Explicit: the canonical project is the one the owner's workspace already
  # counts, which need not be the older of the two.
  defp write(%{action: :duplicate, id: id, duplicate_of: canonical}) do
    case Store.mark_legacy_duplicate(id, canonical, canonical: :explicit) do
      {:ok, _marked} -> :ok
      {:error, reason} -> raise "Marking #{id} a duplicate of #{canonical} failed: #{reason}"
    end
  end

  defp write(_left_alone), do: :ok

  @doc "The summary as lines of text, for the task's output. No secrets."
  @spec format(summary()) :: [String.t()]
  def format(%{applied: applied, projects: lines}) do
    mode = if applied, do: "Applied", else: "Dry run (pass --apply to write)"
    counts = lines |> Enum.frequencies_by(& &1.action) |> Enum.sort()

    tally =
      case counts do
        [] -> "no unassigned projects"
        counts -> Enum.map_join(counts, ", ", fn {action, n} -> "#{n} #{action}" end)
      end

    ["#{mode}: #{tally}"] ++
      Enum.map(lines, fn line ->
        owner = if line.owner, do: "@#{line.owner}", else: "no owner"

        "  #{line.id} #{line.name} (#{line.repo || "no repository"}, #{owner}): " <>
          describe(line)
      end)
  end

  defp describe(%{action: :move, workspace_id: id}), do: "move into personal workspace #{id}"

  defp describe(%{action: :duplicate, duplicate_of: canonical, workspace_id: id}),
    do:
      "not moved: a legacy duplicate of #{canonical}, which holds this repository in " <>
        "personal workspace #{id}; the owner decides which to keep"

  defp describe(%{action: :no_workspace}),
    do: "left alone: the owner has no personal workspace yet"

  defp describe(%{action: :archived}), do: "skipped: archived"
  defp describe(%{action: :deleting}), do: "skipped: deletion requested"
  defp describe(%{action: :legacy_duplicate}), do: "skipped: already a legacy duplicate"
end
