defmodule Ravix.Repo.Migrations.AddProjectHomeRuntimeAndDeletionIntent do
  use Ecto.Migration

  def up do
    alter table(:projects) do
      add :home_runtime, :text
      add :deletion_requested_at, :utc_datetime_usec
    end

    execute "UPDATE ravix.projects SET home_runtime = runtime WHERE home_runtime IS NULL"
  end

  def down do
    alter table(:projects) do
      remove :deletion_requested_at
      remove :home_runtime
    end
  end
end
