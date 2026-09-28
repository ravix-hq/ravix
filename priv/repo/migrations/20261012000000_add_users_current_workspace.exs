defmodule Ravix.Repo.Migrations.AddUsersCurrentWorkspace do
  @moduledoc """
  ADR 0009 follow-up: the workspace a person last chose in the switcher.

  Navigation state, not authority: every read checks it again through
  `Ravix.Accounts.Access.workspace_access/2` and falls back to the default
  when the person is no longer a member. Nullable, and nothing the release
  still serving reads, so this is expand only. A workspace that is deleted
  outright clears it.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :current_workspace_id, references(:workspaces, type: :text, on_delete: :nilify_all)
    end
  end
end
