defmodule Ravix.Repo.Migrations.AddWorkspaceGithubCatalog do
  @moduledoc """
  ADR 0009 phase 4b: connecting GitHub installations to a workspace, and the
  workspace's repository catalog.

  Expand only: two new tables and three nullable columns on
  `workspace_installations`, which nothing in the serving release reads.

    * `workspace_connect_states`: one row per "Connect GitHub" round trip,
      keyed by a hash of the state's nonce together with the workspace, the
      person and their session, so a callback is honoured only for the
      workspace the state names, by the person and browser session that
      began it, once, within fifteen minutes.
    * `workspace_installations` gains `suspended_at`, `status_reason` and
      `refreshed_at`: why a connection's repositories are gone from the
      catalog (suspended on GitHub, uninstalled), shown to the workspace.
    * `workspace_repositories`: the cached catalog, every repository each
      live connection reaches, as of `refreshed_at`. Pages read this and
      never GitHub.
  """
  use Ecto.Migration

  def change do
    create table(:workspace_connect_states, primary_key: false) do
      add :key_hash, :text, primary_key: true
      add :workspace_id, references(:workspaces, type: :text, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:workspace_connect_states, [:created_at], name: :workspace_connect_states_age)

    alter table(:workspace_installations) do
      add :suspended_at, :utc_datetime_usec
      add :status_reason, :text
      add :refreshed_at, :utc_datetime_usec
    end

    create table(:workspace_repositories, primary_key: false) do
      add :id, :text, primary_key: true
      add :workspace_id, references(:workspaces, type: :text, on_delete: :delete_all), null: false

      add :workspace_installation_id,
          references(:workspace_installations, type: :text, on_delete: :delete_all),
          null: false

      add :github_repo_id, :bigint, null: false
      add :full_name, :text, null: false
      add :normalized_repo_full_name, :text, null: false
      add :private, :boolean, null: false, default: false
      add :default_branch, :text
      add :pushed_at, :text
      add :refreshed_at, :utc_datetime_usec, null: false
    end

    create unique_index(:workspace_repositories, [:workspace_installation_id, :github_repo_id],
             name: :workspace_repositories_installation_repo
           )

    create index(:workspace_repositories, [:workspace_id, :normalized_repo_full_name],
             name: :workspace_repositories_workspace_repo
           )
  end
end
