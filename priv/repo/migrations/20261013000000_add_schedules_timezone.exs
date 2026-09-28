defmodule Ravix.Repo.Migrations.AddSchedulesTimezone do
  use Ecto.Migration

  # Expand only: the default keeps existing schedules, and rows the previous
  # release still inserts, on the UTC times they were created with.
  def change do
    alter table(:schedules) do
      add :timezone, :text, null: false, default: "Etc/UTC"
    end
  end
end
