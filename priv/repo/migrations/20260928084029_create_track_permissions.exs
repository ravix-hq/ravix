defmodule Ravix.Repo.Migrations.CreateTrackPermissions do
  @moduledoc """
  ADR 0009 phase 3b: a track shared with selected workspace members, as one
  row per member. Expand only: a new table nothing in the previous release
  reads, so rows written here admit nobody through it.

  A table of its own rather than a kind column on `track_members`, because
  every reader of `track_members` -- including the release still serving
  while this runs -- honours a row there unconditionally. A permission row
  must admit nobody while `RAVIX_WORKSPACE_ACCESS` is off, and nobody who
  has left the track's workspace; neither is something an older reader of
  `track_members` could be taught.

  The row names its workspace so a reader can join the live membership that
  makes it count; revoking that membership voids the row without touching it.
  """
  use Ecto.Migration

  def change do
    create table(:track_permissions, primary_key: false) do
      add :track_id, references(:tracks, type: :text, on_delete: :delete_all), primary_key: true
      add :user_id, references(:users, type: :text, on_delete: :delete_all), primary_key: true

      add :workspace_id, references(:workspaces, type: :text, on_delete: :delete_all), null: false

      add :granted_by_user_id, references(:users, type: :text, on_delete: :nilify_all)
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:track_permissions, [:user_id], name: :track_permissions_user)
  end
end
