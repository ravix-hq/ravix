defmodule Ravix.Repo.Migrations.AddRailFilters do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :rail_scope, :string, null: false, default: "everyone"
    end

    create constraint(:users, :users_rail_scope, check: "rail_scope IN ('everyone', 'mine')")

    create table(:project_closed_views, primary_key: false) do
      add :user_id, references(:users, type: :text, on_delete: :delete_all), primary_key: true

      add :project_id, references(:projects, type: :text, on_delete: :delete_all),
        primary_key: true
    end

    create index(:project_closed_views, [:project_id])
  end
end
