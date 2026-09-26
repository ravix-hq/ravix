defmodule Ravix.Repo.Migrations.AddProjectSections do
  use Ecto.Migration

  def change do
    create table(:project_sections, primary_key: false) do
      add :id, :text, primary_key: true
      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :collapsed, :boolean, null: false, default: false
    end

    create unique_index(:project_sections, [:user_id, :id])
    create unique_index(:project_sections, [:user_id, :name])

    create table(:project_section_placements, primary_key: false) do
      add :user_id, references(:users, type: :text, on_delete: :delete_all), primary_key: true

      add :project_id, references(:projects, type: :text, on_delete: :delete_all),
        primary_key: true

      add :section_id,
          references(:project_sections,
            type: :text,
            with: [user_id: :user_id],
            on_delete: :delete_all
          ),
          null: false
    end

    create index(:project_section_placements, [:section_id])
  end
end
