defmodule Ravix.Repo.Migrations.AddSearchEntries do
  use Ecto.Migration

  def change do
    create table(:search_entries, primary_key: false) do
      add :id, :text, primary_key: true
      add :thread_id, references(:threads, type: :text, on_delete: :delete_all), null: false
      add :conversation_id, :text, null: false
      add :turn_id, :text, null: false
      add :kind, :text, null: false
      add :text, :text, null: false
      add :last_event_id, :bigint, null: false
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create constraint(:search_entries, :search_entries_kind,
             check: "kind IN ('prompt', 'assistant')"
           )

    create index(:search_entries, [:thread_id])
    create index(:search_entries, ["to_tsvector('simple', text)"], using: :gin)

    create index(
             :projects,
             ["to_tsvector('simple', name || ' ' || coalesce(repo_full_name, ''))"],
             using: :gin,
             name: :projects_search_text
           )

    create index(
             :tracks,
             ["to_tsvector('simple', coalesce(title, '') || ' ' || slug || ' ' || branch)"],
             using: :gin,
             name: :tracks_search_text
           )

    create index(:prompt_queue, ["to_tsvector('simple', coalesce(body->>'prompt', ''))"],
             using: :gin,
             name: :prompt_queue_search_text
           )
  end
end
