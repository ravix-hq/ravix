defmodule Ravix.Repo.Migrations.AddProjectPlans do
  use Ecto.Migration

  def up do
    create table(:plans, primary_key: false) do
      add :id, :text, primary_key: true
      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false
      add :title, :text, null: false
      add :summary, :text, null: false, default: ""
      add :version, :integer, null: false, default: 1
      add :created_by_login, :text, null: false
      add :created_by_track_id, references(:tracks, type: :text, on_delete: :nilify_all)
      add :archived, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:plans, [:project_id])

    create table(:plan_items, primary_key: false) do
      add :id, :text, primary_key: true
      add :plan_id, references(:plans, type: :text, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :title, :text, null: false
      add :brief, :text, null: false, default: ""
      add :acceptance, :text, null: false, default: ""
      add :dependencies, {:array, :text}, null: false, default: []
      add :track_id, references(:tracks, type: :text, on_delete: :nilify_all)
      add :assignment_request, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:plan_items, [:plan_id, :position])
    create index(:plan_items, [:track_id])

    create table(:plan_notes, primary_key: false) do
      add :id, :text, primary_key: true
      add :item_id, references(:plan_items, type: :text, on_delete: :delete_all), null: false
      add :body, :text, null: false
      add :created_by_login, :text, null: false
      add :created_by_track_id, references(:tracks, type: :text, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create index(:plan_notes, [:item_id, :inserted_at])

    alter table(:tracks) do
      add :origin_plan_id, references(:plans, type: :text, on_delete: :nilify_all)
      add :origin_item_id, references(:plan_items, type: :text, on_delete: :nilify_all)
    end

    # Widen before removing the old check; old releases keep writing their four kinds.
    create constraint(:tracks, :tracks_origin_kind_expanded,
             check: "origin_kind IN ('blank', 'branch', 'pr', 'issue', 'plan')",
             validate: false
           )

    execute "ALTER TABLE ravix.tracks VALIDATE CONSTRAINT tracks_origin_kind_expanded"
    drop constraint(:tracks, :tracks_origin_kind)

    execute "ALTER TABLE ravix.tracks RENAME CONSTRAINT tracks_origin_kind_expanded TO tracks_origin_kind"

    # Browser actions have a session instead of an OAuth client, but share receipts.
    alter table(:tooling_receipts), do: modify(:client_id, :text, null: true)
    alter table(:tooling_tasks), do: modify(:client_id, :text, null: true)
  end

  def down,
    do: raise("Project plans require a forward migration; existing plans must be preserved")
end
