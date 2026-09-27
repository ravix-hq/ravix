defmodule Ravix.Repo.Migrations.AddThreadCredentialRecovery do
  use Ecto.Migration

  def change do
    alter table(:threads, prefix: "ravix") do
      add :previous_conversation_ids, {:array, :text}, default: [], null: false
      add :credential_recovery, :map
      add :recovery_context_pending, :boolean, default: false, null: false
    end
  end
end
