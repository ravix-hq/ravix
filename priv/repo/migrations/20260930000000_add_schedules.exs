defmodule Ravix.Repo.Migrations.AddSchedules do
  use Ecto.Migration

  def change do
    create table(:schedules, primary_key: false) do
      add :id, :text, primary_key: true
      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :prompt, :text, null: false
      add :frequency, :text, null: false
      add :time, :time, null: false
      add :weekday, :integer, null: false
      add :enabled, :boolean, null: false, default: true
      add :next_run_at, :utc_datetime_usec, null: false
      add :last_run_at, :utc_datetime_usec
      add :last_status, :text
      add :last_track_id, references(:tracks, type: :text, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create index(:schedules, [:user_id])
    create index(:schedules, [:next_run_at], where: "enabled = true")

    create constraint(:schedules, :schedule_frequency,
             check: "frequency IN ('hourly', 'daily', 'weekly')"
           )

    create constraint(:schedules, :schedule_weekday, check: "weekday BETWEEN 1 AND 7")
  end
end
