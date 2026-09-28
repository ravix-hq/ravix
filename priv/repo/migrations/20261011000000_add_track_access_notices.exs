defmodule Ravix.Repo.Migrations.AddTrackAccessNotices do
  @moduledoc """
  ADR 0009 phase 5: sharing after workspace membership.

  `track_access_notices` is the Inbox note the invite-link cutover
  (`Ravix.People.Cutover`) leaves a track's creator: who lost access to the
  track because they are not in its workspace, and whose waiting invitation
  was withdrawn. One per track and recipient, which is what keeps a second
  run of the cutover from writing a second note.

  A new table, so the release still serving while this runs never sees
  it: expand only.
  """
  use Ecto.Migration

  def change do
    create table(:track_access_notices, primary_key: false) do
      add :id, :text, primary_key: true
      add :track_id, references(:tracks, type: :text, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :workspace_id, references(:workspaces, type: :text, on_delete: :delete_all), null: false

      # Display only: logins as they were when access ended.
      add :revoked_logins, {:array, :text}, null: false, default: []
      add :withdrawn_logins, {:array, :text}, null: false, default: []
      add :created_at, :utc_datetime_usec, null: false
      add :dismissed_at, :utc_datetime_usec
    end

    create unique_index(:track_access_notices, [:track_id, :user_id])
    create index(:track_access_notices, [:user_id], where: "dismissed_at IS NULL")
  end
end
