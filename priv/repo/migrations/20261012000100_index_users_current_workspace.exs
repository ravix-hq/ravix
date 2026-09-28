defmodule Ravix.Repo.Migrations.IndexUsersCurrentWorkspace do
  @moduledoc """
  An index behind `users.current_workspace_id`'s `ON DELETE SET NULL`, so
  deleting a workspace does not scan every user. Built concurrently, so the
  release still serving keeps writing `users` while it builds: expand only.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:users, [:current_workspace_id], concurrently: true)
  end
end
