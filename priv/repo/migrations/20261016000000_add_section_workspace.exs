defmodule Ravix.Repo.Migrations.AddSectionWorkspace do
  @moduledoc """
  RAV-127: a sidebar section belongs to one of the person's workspaces.

  Expand only. The column is nullable because the release still serving
  inserts sections without it; this release reads such a row as the
  person's personal workspace, and `Ravix.Workspaces.Backfill` fills it in
  after every migration. The new uniqueness is `(user_id, workspace_id,
  name)`, so the same name may exist once per workspace.

  The old `(user_id, name)` index is kept under its own name, narrowed to
  the rows with no workspace: it still refuses the previous release's
  duplicate names, and that release's `unique_constraint` still finds
  `project_sections_user_id_name_index` when it does. Rows this release
  writes carry a workspace, so the narrowed index lets the backfill split a
  section into same-named copies. The `contract` item makes the column NOT
  NULL and drops the narrowed index once no serving release writes nulls.
  """
  use Ecto.Migration

  def change do
    alter table(:project_sections) do
      add :workspace_id, references(:workspaces, type: :text, on_delete: :delete_all)
    end

    create unique_index(:project_sections, [:user_id, :workspace_id, :name])

    drop unique_index(:project_sections, [:user_id, :name])
    create unique_index(:project_sections, [:user_id, :name], where: "workspace_id IS NULL")
  end
end
