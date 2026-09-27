defmodule Ravix.Repo.Migrations.AddTurnFailures do
  use Ecto.Migration

  def change do
    create table(:track_turn_failures, primary_key: false) do
      add :conversation_id, :text, primary_key: true
      add :turn_id, :text, primary_key: true
      add :stage, :text, primary_key: true
      add :state, :text, null: false
      add :code, :text, null: false
      add :reason, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    alter table(:tooling_tasks) do
      add :failure_code, :text
      add :failure_message, :text
    end
  end
end
