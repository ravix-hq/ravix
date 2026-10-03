defmodule Ravix.Repo.Migrations.AddWebhookRoutines do
  use Ecto.Migration

  def change do
    create table(:routines, primary_key: false) do
      add :id, :text, primary_key: true
      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :prompt, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :credential_hash, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:routines, [:user_id])

    create table(:routine_dispatches, primary_key: false) do
      add :id, :text, primary_key: true
      add :routine_id, references(:routines, type: :text, on_delete: :delete_all), null: false
      add :request_id, :text, null: false
      add :payload_hash, :text, null: false
      add :status, :text, null: false, default: "dispatching"
      add :track_id, references(:tracks, type: :text, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:routine_dispatches, [:routine_id, :request_id])
    create index(:routine_dispatches, [:routine_id, :inserted_at])
  end
end
