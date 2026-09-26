defmodule Ravix.Repo.Migrations.AddToolingGrantLastUsedAt do
  use Ecto.Migration

  def change do
    alter table(:tooling_grants) do
      add :last_used_at, :utc_datetime_usec
    end
  end
end
