defmodule Ravix.Repo.Migrations.CreateProjects do
  @moduledoc """
  Projects and the wider membership: members, invites, one link.

  The three Fountain ids are the project. They are written once, at
  creation, and never updated: the sandbox is built from them, so a row
  that changed one would be a row pointing at a different machine.
  """
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :text, primary_key: true

      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false

      add :name, :text, null: false
      add :repo_full_name, :text
      add :repo_private, :boolean, null: false, default: false
      add :default_branch, :text
      add :installation_id, :bigint
      add :agent_id, :text, null: false
      add :environment_id, :text, null: false
      add :vault_id, :text
      add :runtime, :text, null: false
      add :model, :text, null: false
      add :rev, :integer, null: false, default: 1
      add :instructions, :text, null: false, default: ""
      add :created_at, :utc_datetime_usec, null: false
      add :archived_at, :utc_datetime_usec
    end

    create index(:projects, [:user_id, :archived_at], name: :projects_user)

    # Who else is in a project. Somebody here reaches every track on the
    # project and may open tracks of their own, but not the project's
    # controls: those are the machine rather than the work on it.
    create table(:project_members, primary_key: false) do
      add :project_id, references(:projects, type: :text, on_delete: :delete_all),
        primary_key: true

      add :user_id, references(:users, type: :text, on_delete: :delete_all), primary_key: true

      add :invited_by, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:project_members, [:user_id], name: :project_members_user)

    # Keyed on GitHub's numeric id: a login is renameable and reusable, so an
    # invitation matched on the name would eventually attach to whoever
    # holds it on the day they arrive. Here that would hand a stranger the
    # whole machine rather than one branch.
    create table(:project_invites, primary_key: false) do
      add :project_id, references(:projects, type: :text, on_delete: :delete_all),
        primary_key: true

      add :github_id, :text, primary_key: true
      add :login, :text, null: false
      add :avatar_url, :text
      add :invited_by, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:project_invites, [:github_id], name: :project_invites_github)

    # One link per project, hashed, minting is the revoke.
    create table(:project_links, primary_key: false) do
      add :project_id, references(:projects, type: :text, on_delete: :delete_all),
        primary_key: true

      add :token_hash, :text, null: false
      add :created_by, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create unique_index(:project_links, [:token_hash])
  end
end
