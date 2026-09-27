defmodule Ravix.Repo.Migrations.AddToolingTaskReconciledAt do
  use Ecto.Migration

  def change do
    alter table(:tooling_tasks) do
      add :reconciled_at, :utc_datetime_usec
    end
  end
end
