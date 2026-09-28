defmodule Ravix.Repo.Migrations.AddWorkspaceInvites do
  @moduledoc """
  ADR 0009 phase 4a: an invitation to a workspace for somebody who has not
  signed in here yet, waiting on their GitHub login.

  A new table, so the release still serving while this runs never sees it.
  `login_key` is the login lowercased, as GitHub compares logins; one
  waiting invitation per login per workspace. `github_id` is the identity
  that survives a rename, kept when GitHub could say who the login is, and
  when it is present sign-in matches on it alone. `invited_by_role` is the
  inviter's role at the time, so an admin cannot rewrite or withdraw what
  an owner sent.
  """
  use Ecto.Migration

  def change do
    create table(:workspace_invites, primary_key: false) do
      add :id, :text, primary_key: true
      add :workspace_id, references(:workspaces, type: :text, on_delete: :delete_all), null: false
      add :login, :text, null: false
      add :login_key, :text, null: false
      add :github_id, :text
      add :avatar_url, :text
      add :role, :text, null: false
      add :invited_by_user_id, references(:users, type: :text, on_delete: :nilify_all)
      # The inviter's role when they sent it: an owner's invitation is theirs
      # to change or withdraw, not an admin's.
      add :invited_by_role, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create constraint(:workspace_invites, :workspace_invites_role,
             check: "role IN ('owner', 'admin', 'member')"
           )

    create constraint(:workspace_invites, :workspace_invites_invited_by_role,
             check: "invited_by_role IN ('owner', 'admin', 'member')"
           )

    create unique_index(:workspace_invites, [:workspace_id, :login_key],
             name: :workspace_invites_workspace_login
           )

    create index(:workspace_invites, [:login_key], name: :workspace_invites_login)
    create index(:workspace_invites, [:github_id], name: :workspace_invites_github)
  end
end
