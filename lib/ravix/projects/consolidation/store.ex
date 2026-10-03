defmodule Ravix.Projects.Consolidation.Store do
  @moduledoc """
  Repository-only operator cutover. Run after all instances understand resources,
  with serving instances stopped; provider machines and conversations stay running.
  """
  import Ecto.Query
  alias Ravix.Projects.Project
  alias Ravix.Repo

  @resource_fields ~w(user_id agent_id environment_id vault_id runtime model credential_set_id
    home_runtime shared_home_runtime runtime_agents_retiring secrets_generation secrets_pending
    shared_machine_retiring rev instructions installation_id repo_full_name repo_private
    default_branch created_at archived_at deletion_requested_at)

  @doc "Duplicate repository groups in one workspace; scratch projects are not candidates."
  def groups(workspace_id) do
    Repo.all(
      from p in Project, where: p.workspace_id == ^workspace_id, order_by: [p.created_at, p.id]
    )
    |> Enum.group_by(&Project.normalize_repo(&1.repo_full_name))
    |> Enum.reject(fn {repo, projects} -> is_nil(repo) or length(projects) < 2 end)
    |> Enum.map(fn {repo, projects} ->
      canonical =
        Enum.find(
          projects,
          &(is_nil(&1.legacy_duplicate_at) and &1.normalized_repo_full_name == repo)
        ) ||
          Enum.find(projects, &is_nil(&1.legacy_duplicate_at)) || hd(projects)

      %{
        repo: repo,
        canonical_id: canonical.id,
        donor_ids: Enum.map(projects -- [canonical], & &1.id),
        inventory: Enum.map(projects, &inventory/1)
      }
    end)
    |> Enum.sort_by(& &1.repo)
  end

  # Only the literal table allowlist below is interpolated; project IDs are bound parameters.
  # sobelow_skip ["SQL.Query"]
  defp inventory(project) do
    tables =
      ~w(tracks plans schedules routines preview_defaults project_runtime_agents project_members project_invites project_links)

    counts =
      Map.new(tables, fn table ->
        %{rows: [[count]]} =
          Repo.query!("SELECT count(*) FROM ravix.#{table} WHERE project_id = $1", [project.id])

        {table, count}
      end)

    %{
      project_id: project.id,
      owner_id: project.user_id,
      archived: not is_nil(project.archived_at),
      deleting: not is_nil(project.deletion_requested_at),
      counts: counts
    }
  end

  @doc "Close the normalization/legacy-marker index exemptions in the completed workspace."
  def finish_workspace(workspace_id) do
    Repo.query!(
      """
      UPDATE ravix.projects
      SET normalized_repo_full_name = NULLIF(lower(btrim(repo_full_name, E' \\t\\r\\n')), ''),
          legacy_duplicate_of = NULL, legacy_duplicate_at = NULL
      WHERE workspace_id = $1
      """,
      [workspace_id]
    )

    :ok
  end

  @doc "Atomically move one duplicate into its workspace's canonical repository project."
  def merge(workspace_id, canonical_id, donor_id) do
    Repo.transaction(fn ->
      projects =
        Repo.all(
          from p in Project,
            where: p.id in ^[canonical_id, donor_id],
            order_by: p.id,
            lock: "FOR UPDATE"
        )

      canonical = Enum.find(projects, &(&1.id == canonical_id))
      donor = Enum.find(projects, &(&1.id == donor_id))
      validate_pair!(workspace_id, canonical, donor)
      # These primary keys must remain through the rolling expansion: old
      # binaries still use ON CONFLICT(project_id[, runtime]). Only this
      # maintenance cutover can contract them to the resource-aware indexes.
      Repo.query!(
        "ALTER TABLE ravix.project_runtime_agents DROP CONSTRAINT IF EXISTS project_runtime_agents_pkey"
      )

      Repo.query!(
        "ALTER TABLE ravix.preview_defaults DROP CONSTRAINT IF EXISTS preview_defaults_pkey"
      )

      preserve_resource(canonical, donor)
      preserve_sharing(canonical, donor)
      move_references(canonical, donor)
      Repo.delete!(donor)

      Repo.update_all(from(p in Project, where: p.id == ^canonical.id),
        set: [
          normalized_repo_full_name: Project.normalize_repo(canonical.repo_full_name),
          legacy_duplicate_of: nil,
          legacy_duplicate_at: nil,
          name: canonical.repo_full_name
        ]
      )

      %{canonical_id: canonical.id, removed_id: donor.id}
    end)
  end

  defp validate_pair!(_workspace_id, nil, _donor), do: Repo.rollback(:not_found)
  defp validate_pair!(_workspace_id, _canonical, nil), do: Repo.rollback(:not_found)
  defp validate_pair!(nil, _canonical, _donor), do: Repo.rollback(:different_workspace)

  defp validate_pair!(workspace_id, canonical, donor) do
    cond do
      canonical.id == donor.id ->
        Repo.rollback(:same_project)

      canonical.workspace_id != workspace_id or donor.workspace_id != workspace_id ->
        Repo.rollback(:different_workspace)

      canonical.deletion_requested_at || donor.deletion_requested_at ->
        Repo.rollback(:deleting)

      canonical.archived_at ->
        Repo.rollback(:canonical_archived)

      donor.archived_at ->
        Repo.rollback(:donor_archived)

      true ->
        validate_repository!(canonical, donor)
    end
  end

  defp validate_repository!(canonical, donor) do
    repo = Project.normalize_repo(canonical.repo_full_name)

    if is_nil(repo) or repo != Project.normalize_repo(donor.repo_full_name),
      do: Repo.rollback(:different_repository)
  end

  # Columns come only from @resource_fields; both project IDs are bound parameters.
  # sobelow_skip ["SQL.Query"]
  defp preserve_resource(canonical, donor) do
    columns = Enum.join(@resource_fields, ", ")

    Repo.query!(
      """
      INSERT INTO ravix.project_resources (id, project_id, #{columns})
      SELECT id, $1, #{columns} FROM ravix.projects WHERE id = $2
      """,
      [canonical.id, donor.id]
    )
  end

  # Interpolated table names are literal constants; all row values are bound parameters.
  # sobelow_skip ["SQL.Query"]
  defp preserve_sharing(canonical, donor) do
    for table <- ~w(project_invites project_links) do
      Repo.query!("UPDATE ravix.#{table} SET resource_scoped = true WHERE project_id = $1", [
        canonical.id
      ])
    end

    # Existing project guests keep only the tracks they could already reach.
    # Workspace roles still grant the same workspace-wide access as before.
    for project <- [canonical, donor] do
      Repo.query!(
        """
        INSERT INTO ravix.track_members (track_id, user_id, invited_by, created_at, role)
        SELECT t.id, m.user_id, m.invited_by, m.created_at, m.role
        FROM ravix.project_members m JOIN ravix.tracks t ON t.project_id = m.project_id
        WHERE m.project_id = $1 AND t.visibility = 'project'
        ON CONFLICT (track_id, user_id) DO UPDATE SET role = CASE
          WHEN track_members.role = 'admin' OR EXCLUDED.role = 'admin' THEN 'admin'
          WHEN COALESCE(track_members.role, 'write') = 'write'
            OR COALESCE(EXCLUDED.role, 'write') = 'write' THEN 'write'
          ELSE 'read' END
        """,
        [project.id]
      )

      Repo.query!("DELETE FROM ravix.project_members WHERE project_id = $1", [project.id])
    end

    # Ownership admitted project-visible tracks; a private track still needs
    # its creator or a direct seat, even for the original project owner.
    if donor.user_id != canonical.user_id do
      Repo.query!(
        """
        INSERT INTO ravix.track_members (track_id, user_id, invited_by, created_at, role)
        SELECT id, $2, $2, $3, 'admin' FROM ravix.tracks
        WHERE project_id = $1 AND (visibility = 'project' OR
          (created_by = $2 AND creator_revoked_at IS NULL))
        ON CONFLICT (track_id, user_id) DO UPDATE SET role = 'admin'
        """,
        [donor.id, donor.user_id, donor.created_at]
      )
    end

    Repo.query!(
      """
      INSERT INTO ravix.resource_invites
        (resource_id, github_id, login, avatar_url, invited_by, created_at)
      SELECT project_id, github_id, login, avatar_url, invited_by, created_at
      FROM ravix.project_invites WHERE project_id = $1
      """,
      [donor.id]
    )

    Repo.query!(
      """
      INSERT INTO ravix.resource_links (resource_id, token_hash, created_by, created_at, expires_at)
      SELECT project_id, token_hash, created_by, created_at, expires_at
      FROM ravix.project_links WHERE project_id = $1
      """,
      [donor.id]
    )
  end

  # Interpolated table names are literal constants; both project IDs are bound parameters.
  # sobelow_skip ["SQL.Query"]
  defp move_references(canonical, donor) do
    for table <- ~w(tracks plans schedules routines project_runtime_agents preview_defaults) do
      Repo.query!(
        "UPDATE ravix.#{table} SET project_id = $1, resource_id = COALESCE(resource_id, $2) WHERE project_id = $2",
        [canonical.id, donor.id]
      )
    end

    Repo.query!("UPDATE ravix.project_resources SET project_id = $1 WHERE project_id = $2", [
      canonical.id,
      donor.id
    ])

    # A canonical project's existing preference wins when both exist; otherwise
    # the donor's placement/filter transfers. The section rows themselves stay.
    Repo.query!(
      """
      INSERT INTO ravix.project_section_placements (project_id, user_id, section_id)
      SELECT $1, user_id, section_id FROM ravix.project_section_placements WHERE project_id = $2
      ON CONFLICT (user_id, project_id) DO NOTHING
      """,
      [canonical.id, donor.id]
    )

    Repo.query!(
      """
      INSERT INTO ravix.project_closed_views (project_id, user_id)
      SELECT $1, user_id FROM ravix.project_closed_views WHERE project_id = $2
      ON CONFLICT (user_id, project_id) DO NOTHING
      """,
      [canonical.id, donor.id]
    )

    Repo.query!(
      "UPDATE ravix.workspace_repository_reservations SET canonical_project_id = $1 WHERE canonical_project_id = $2",
      [canonical.id, donor.id]
    )

    Repo.query!(
      "UPDATE ravix.projects SET legacy_duplicate_of = $1 WHERE legacy_duplicate_of = $2",
      [canonical.id, donor.id]
    )
  end
end
