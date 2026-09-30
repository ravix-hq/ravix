defmodule Ravix.Repo.Migrations.CreateTerminalTabs do
  @moduledoc """
  RAV-54: interactive terminals on the track machine.

  `terminal_tabs` is one person's open terminal on one track: the sprite it
  runs on and, once Sprites has named it, the exec session to re-attach to.
  It is what lets a LiveView that reconnects --- to this instance or another
  --- find its terminals again, since the process holding the socket went
  with the old one. Nothing secret is stored: a session id is useless
  without the deployment's Sprites token.

  A new table, so the release still serving while this runs never sees
  it: expand only.
  """
  use Ecto.Migration

  def change do
    create table(:terminal_tabs, primary_key: false) do
      add :id, :text, primary_key: true
      add :track_id, references(:tracks, type: :text, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :sprite, :text, null: false
      add :session_id, :text
      add :number, :integer, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:terminal_tabs, [:track_id, :user_id])
    create unique_index(:terminal_tabs, [:track_id, :user_id, :number])
  end
end
