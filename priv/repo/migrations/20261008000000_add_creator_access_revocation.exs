defmodule Ravix.Repo.Migrations.AddCreatorAccessRevocation do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :creator_revoked_at, :utc_datetime_usec
    end
  end
end
