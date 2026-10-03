defmodule Ravix.Repo.Migrations.ExpandProjectResources do
  use Ecto.Migration

  def up do
    # No projects move here: older instances still address provider resources
    # through projects. Consolidation is an explicit post-deploy operator step.
    create table(:project_resources, primary_key: false) do
      add :id, :text, primary_key: true
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :text), null: false
      add :agent_id, :text, null: false
      add :environment_id, :text, null: false
      add :vault_id, :text
      add :runtime, :text, null: false
      add :model, :text, null: false
      add :credential_set_id, :text
      add :home_runtime, :text
      add :shared_home_runtime, :text
      add :runtime_agents_retiring, :boolean, null: false, default: false
      add :secrets_generation, :integer, null: false, default: 0
      add :secrets_pending, :boolean, null: false, default: false
      add :shared_machine_retiring, :boolean, null: false, default: false
      add :rev, :integer, null: false
      add :instructions, :text, null: false
      add :installation_id, :bigint
      add :repo_full_name, :text
      add :repo_private, :boolean, null: false, default: false
      add :default_branch, :text
      add :created_at, :utc_datetime_usec, null: false
      add :archived_at, :utc_datetime_usec
      add :deletion_requested_at, :utc_datetime_usec
    end

    create index(:project_resources, [:project_id])

    create table(:resource_invites, primary_key: false) do
      add :resource_id, references(:project_resources, type: :text, on_delete: :delete_all),
        primary_key: true

      add :github_id, :text, primary_key: true
      add :login, :text, null: false
      add :avatar_url, :text
      add :invited_by, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create table(:resource_links, primary_key: false) do
      add :resource_id, references(:project_resources, type: :text, on_delete: :delete_all),
        primary_key: true

      add :token_hash, :text, null: false
      add :created_by, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create unique_index(:resource_links, [:token_hash])

    for name <- [:project_invites, :project_links] do
      alter table(name) do
        add :resource_scoped, :boolean, null: false, default: false
      end
    end

    for name <- [
          :tracks,
          :plans,
          :schedules,
          :routines,
          :project_runtime_agents,
          :preview_defaults
        ] do
      alter table(name) do
        add :resource_id, references(:project_resources, type: :text)
      end
    end

    drop index(:tracks, [:project_id, :slug], name: :tracks_slug)
    drop index(:tracks, [:project_id, :branch], name: :tracks_branch)

    create unique_index(:tracks, ["COALESCE(resource_id, project_id)", :slug],
             name: :tracks_slug,
             where: "closed_at IS NULL"
           )

    create unique_index(:tracks, ["COALESCE(resource_id, project_id)", :branch],
             name: :tracks_branch,
             where: "branch_reserved"
           )

    create unique_index(:project_runtime_agents, ["COALESCE(resource_id, project_id)", :runtime],
             name: :project_runtime_agents_identity
           )

    create unique_index(:preview_defaults, ["COALESCE(resource_id, project_id)"],
             name: :preview_defaults_identity
           )

    # Old releases omit the normalized field; keep the existing unique index
    # effective for their writes too. Existing duplicate rows move only at cutover.
    execute("""
    CREATE FUNCTION ravix.normalize_project_repository() RETURNS trigger AS $$
    BEGIN
      NEW.normalized_repo_full_name = NULLIF(lower(btrim(NEW.repo_full_name, E' \\t\\r\\n')), '');
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER normalize_project_repository
    BEFORE INSERT OR UPDATE OF repo_full_name, normalized_repo_full_name ON ravix.projects
    FOR EACH ROW EXECUTE FUNCTION ravix.normalize_project_repository()
    """)
  end

  def down do
    raise "project resource expansion requires a reviewed rollback before dropping preserved resources"
  end
end
