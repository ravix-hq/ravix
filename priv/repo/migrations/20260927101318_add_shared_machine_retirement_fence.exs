defmodule Ravix.Repo.Migrations.AddSharedMachineRetirementFence do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :shared_machine_retiring, :boolean, default: false, null: false
    end
  end
end
