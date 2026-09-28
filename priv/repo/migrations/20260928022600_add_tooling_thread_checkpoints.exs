defmodule Ravix.Repo.Migrations.AddToolingThreadCheckpoints do
  use Ecto.Migration

  def change do
    create table(:tooling_thread_checkpoints, primary_key: false) do
      add :id, references(:threads, type: :text, on_delete: :delete_all), primary_key: true
      add :conversation_id, :text, primary_key: true
      add :cursor, :bigint
      add :signature, :text
      add :unchanged, :integer, null: false, default: 0
      add :next_due_at, :utc_datetime_usec
      add :generation, :bigint, null: false, default: 0
    end

    alter table(:tooling_tasks) do
      add :cursor_conversation_id, :text
      add :reply_events, {:array, :map}
      add :turn_seen, :boolean, null: false, default: false
      add :reply_prefix, :text, null: false, default: ""
    end
  end
end
