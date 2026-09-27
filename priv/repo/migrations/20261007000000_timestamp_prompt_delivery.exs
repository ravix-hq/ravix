defmodule Ravix.Repo.Migrations.TimestampPromptDelivery do
  use Ecto.Migration

  def change do
    alter table(:prompt_queue) do
      add :delivered_at, :utc_datetime_usec
    end
  end
end
