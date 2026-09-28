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
    * everything else moves. Its legacy owner, project members, tracks and
      track seats stay as they are, so every legacy door still admits
      whoever it did. Waiting invitations and links stop working once the
      project has a workspace (`Ravix.People.workspace_sharing?/1`), so the
      report lists, per project, who else holds what, and marks the lines
      that lose something. `Ravix.People.Cutover` leaves projects in a
      personal workspace alone, so a later cutover run keeps those seats.

  A dry run by default: `run(apply: false)` works out and returns the plan
  and writes nothing. `run(apply: true)` writes it, one project at a time,
  each write conditional on the row still being unassigned and live, so a
  run cut off halfway, or run again, picks up exactly what is left and a
  finished one changes nothing. A row that changed since the plan, or a
  repository that reached the workspace meanwhile, is reported per project
  rather than aborting the run. The summary holds ids, names, logins and
  repositories, never a secret.

  Needs the `Ravix.Repo` and nothing else: `Ravix.Release.assign_personal_workspaces/1`
  runs it without starting the application, so no singleton or endpoint
  starts beside the serving release.

  An operator step, run as no user: every row it touches goes through
  `Ravix.Workspaces.Store`.
  """

  alias Ravix.People.Store, as: People
  alias Ravix.Projects.Project
  alias Ravix.Workspaces.Store

  @type action ::
          :move | :duplicate | :no_workspace | :archived | :deleting | :legacy_duplicate
  @typedoc "What an applied write did: nil on a dry run and for a line left alone."
  @type result :: :moved | :marked | :skipped | :collision | {:failed, atom()} | nil
  @type line :: %{
          id: String.t(),
          name: String.t(),
          repo: String.t() | nil,
          owner: String.t() | nil,
          workspace_id: String.t() | nil,
          action: action(),
          duplicate_of: String.t() | nil,
          canonical_state: :live | :archived | :deleting | nil,
          # ownership: no door -- a type only; the operator step reads it below.
          sharing: People.inventory(),
          result: result()
        }
  @type summary :: %{applied: boolean(), projects: [line()]}

  @doc "Work out the assignment, and write it when `apply: true`."
  @spec run(keyword()) :: {:ok, summary()}
  def run(opts \\ []) do
    lines = plan()

    if Keyword.get(opts, :apply, false) do
      {:ok, %{applied: true, projects: Enum.map(lines, &%{&1 | result: write(&1)})}}
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

    # ownership: no door -- the operator data step; who else holds anything
    # on these projects, reported so that nobody's access changes unseen.
    sharing = People.inventory(Enum.map(rows, & &1.project))

    {lines, _holders} =
      Enum.map_reduce(rows, holders, fn row, holders ->
        line(row, Map.fetch!(sharing, row.project.id), holders)
      end)

    lines
  end

  defp line(%{project: project, login: login, workspace_id: workspace_id}, sharing, holders) do
    base = %{
      id: project.id,
      name: project.name,
      repo: project.repo_full_name,
      owner: login,
      workspace_id: workspace_id,
      action: :move,
      duplicate_of: nil,
      canonical_state: nil,
      sharing: sharing,
      result: nil
    }

    key = {workspace_id, repo_key(project)}

    cond do
      project.legacy_duplicate_at -> {%{base | action: :legacy_duplicate}, holders}
      project.archived_at -> {%{base | action: :archived}, holders}
      project.deletion_requested_at -> {%{base | action: :deleting}, holders}
      is_nil(workspace_id) -> {%{base | action: :no_workspace}, holders}
      is_nil(elem(key, 1)) -> {base, holders}
      holder = holders[key] -> {duplicate(base, holder), holders}
      true -> {base, Map.put(holders, key, %{id: project.id, state: :live})}
    end
  end

  defp duplicate(base, holder),
    do: %{base | action: :duplicate, duplicate_of: holder.id, canonical_state: holder.state}

  defp repo_key(%Project{} = project),
    do: project.normalized_repo_full_name || Project.normalize_repo(project.repo_full_name)

  # Each write re-checks the row, so a project archived, deleted, moved or
  # collided with since the plan is reported rather than written or fatal.
  defp write(%{action: :move, id: id, workspace_id: workspace_id}),
    do: Store.assign_personal(id, workspace_id)

  # Explicit: the canonical project is the one the owner's workspace already
  # counts, which need not be the older of the two.
  defp write(%{action: :duplicate, id: id, duplicate_of: canonical}) do
    case Store.mark_legacy_duplicate(id, canonical, canonical: :explicit) do
      {:ok, _marked} -> :marked
      {:error, reason} -> {:failed, reason}
    end
  end

  defp write(_left_alone), do: nil

  @doc """
  The summary as lines of text, for the task's output. No secrets.

  Each project line is followed by who else holds anything on it. Legacy
  project members and track seats carry over into the workspace; waiting
  invitations and unexpired links stop working once a project has a
  workspace, so a line with either is marked `LOSES`.
  """
  @spec format(summary()) :: [String.t()]
  def format(%{applied: applied, projects: lines}) do
    mode = if applied, do: "Applied", else: "Dry run (pass --apply to write)"
    counts = lines |> Enum.frequencies_by(& &1.action) |> Enum.sort()

    tally =
      case counts do
        [] -> "no unassigned projects"
        counts -> Enum.map_join(counts, ", ", fn {action, n} -> "#{n} #{action}" end)
      end

    losing = Enum.count(lines, &(moving?(&1) and loses?(&1.sharing)))

    ["#{mode}: #{tally}"] ++
      if(losing > 0,
        do: ["#{losing} moving project(s) have waiting invitations or links that stop working"],
        else: []
      ) ++
      Enum.flat_map(lines, fn line ->
        owner = if line.owner, do: "@#{line.owner}", else: "no owner"

        [
          "  #{line.id} #{line.name} (#{line.repo || "no repository"}, #{owner}): " <>
            describe(line) <> outcome(line.result)
        ] ++ sharing_line(line)
      end)
  end

  defp moving?(line), do: line.action == :move and line.result in [nil, :moved]

  defp loses?(sharing), do: sharing.invites != [] or sharing.links > 0

  defp sharing_line(%{sharing: sharing} = line) do
    parts =
      [
        sharing.members != [] && "project members #{logins(sharing.members)} (kept)",
        sharing.seats != [] && "track seats #{logins(sharing.seats)} (kept)",
        sharing.invites != [] && "waiting invitations #{logins(sharing.invites)}",
        sharing.links > 0 && "#{sharing.links} unexpired link(s)"
      ]
      |> Enum.filter(& &1)

    cond do
      parts == [] ->
        []

      moving?(line) and loses?(sharing) ->
        ["    LOSES invitations/links; " <> Enum.join(parts, "; ")]

      true ->
        ["    shared: " <> Enum.join(parts, "; ")]
    end
  end

  defp logins(list), do: Enum.map_join(list, ", ", &("@" <> &1))

  defp describe(%{action: :move, workspace_id: id}), do: "move into personal workspace #{id}"

  defp describe(%{action: :duplicate, duplicate_of: canonical, workspace_id: id} = line),
    do:
      "not moved: a legacy duplicate of #{canonical}, which holds this repository in " <>
        "personal workspace #{id}#{canonical_note(line.canonical_state)}; " <>
        "the owner decides which to keep"

  defp describe(%{action: :no_workspace}),
    do: "left alone: the owner has no personal workspace yet"

  defp describe(%{action: :archived}), do: "skipped: archived"
  defp describe(%{action: :deleting}), do: "skipped: deletion requested"
  defp describe(%{action: :legacy_duplicate}), do: "skipped: already a legacy duplicate"

  defp canonical_note(:archived), do: " (that project is archived)"
  defp canonical_note(:deleting), do: " (that project is being deleted)"
  defp canonical_note(_live), do: ""

  defp outcome(nil), do: ""
  defp outcome(:moved), do: " -> moved"
  defp outcome(:marked), do: " -> marked"

  defp outcome(:skipped),
    do: " -> skipped at write: no longer unassigned, live and unmarked"

  defp outcome(:collision),
    do: " -> not moved: the workspace gained a project for this repository since the plan"

  defp outcome({:failed, reason}), do: " -> not marked: #{reason}"
end
