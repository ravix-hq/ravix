defmodule Ravix.Repo.Migrations.AddChangesSeenAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :changes_seen_at, :utc_datetime_usec
    end
  end
end
