defmodule Ravix.Repo.Migrations.AddSandboxOperationLeasesAndSecretRevisions do
  use Ecto.Migration

  def change do
    alter table(:track_sandbox_operations) do
      add :phase, :string, null: false, default: "pending"
      add :lease, :string
      add :lease_until, :utc_datetime_usec
      add :retry_at, :utc_datetime_usec
    end

    alter table(:tracks) do
      add :sandbox_stage, :string
      add :secrets_generation, :bigint, null: false, default: 0
    end

    alter table(:projects) do
      add :secrets_generation, :bigint, null: false, default: 0
      add :secrets_pending, :boolean, null: false, default: false
    end

    create index(:track_sandbox_operations, [:retry_at],
             where: "completed_at IS NULL",
             name: :sandbox_operations_pending
           )
  end
end
