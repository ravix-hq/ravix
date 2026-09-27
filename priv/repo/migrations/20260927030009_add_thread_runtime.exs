defmodule Ravix.Repo.Migrations.AddThreadRuntime do
  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :runtime, :text
      add :model, :text
    end

    alter table(:tracks) do
      add :last_runtime, :text
    end

    alter table(:projects) do
      add :runtime_agents_retiring, :boolean, null: false, default: false
    end

    create table(:project_runtime_agents, primary_key: false) do
      add :project_id, references(:projects, type: :text, on_delete: :delete_all),
        primary_key: true

      add :runtime, :text, primary_key: true
      add :agent_id, :text
      add :credential_set_id, :text
    end
  end
end
