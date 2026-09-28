defmodule Ravix.Repo.Migrations.AddThreadPreferences do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :preferred_runtime, :string
      add :preferred_model, :string
      add :credential_connected_at, :map, default: %{}, null: false
    end

    create constraint(:users, :users_preferred_runtime,
             check: "preferred_runtime IS NULL OR preferred_runtime IN ('claude', 'codex')"
           )
  end
end
