defmodule Ravix.Repo.Migrations.AddDiffReviews do
  use Ecto.Migration

  # Expand-only; previous releases do not read these tables.
  def change do
    create table(:review_discussions, primary_key: false) do
      add :id, :text, primary_key: true
      add :track_id, references(:tracks, type: :text, on_delete: :delete_all), null: false
      add :revision, :text, null: false
      add :path, :text, null: false
      add :side, :text, null: false
      add :line, :integer
      add :excerpt, :text
      add :resolved, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:review_discussions, [:track_id, :inserted_at])

    create constraint(:review_discussions, :review_anchor,
             check:
               "(side = 'file' AND line IS NULL) OR (side IN ('old', 'new') AND line IS NOT NULL AND line > 0)"
           )

    create table(:review_messages, primary_key: false) do
      add :id, :text, primary_key: true

      add :discussion_id, references(:review_discussions, type: :text, on_delete: :delete_all),
        null: false

      add :author_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :body, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:review_messages, [:discussion_id, :inserted_at])

    create constraint(:review_messages, :review_body,
             check: "length(btrim(body)) BETWEEN 1 AND 10000"
           )
  end
end
