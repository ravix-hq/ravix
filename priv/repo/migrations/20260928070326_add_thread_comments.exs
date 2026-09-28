defmodule Ravix.Repo.Migrations.AddThreadComments do
  use Ecto.Migration

  # Expand-only: two new tables that nothing running reads yet.
  def change do
    create table(:thread_comments, primary_key: false) do
      add :id, :text, primary_key: true
      add :track_id, references(:tracks, type: :text, on_delete: :delete_all), null: false
      add :thread_id, references(:threads, type: :text, on_delete: :delete_all), null: false
      add :author_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :body, :text, null: false
      # Where the comment sits in the transcript: the last visible turn, and
      # the newest event, when it was posted. Nil on an empty thread.
      add :conversation_id, :text
      add :anchor_turn_id, :text
      add :anchor_event_id, :bigint
      add :inserted_at, :utc_datetime_usec, null: false
      add :edited_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec
    end

    create index(:thread_comments, [:thread_id, :inserted_at])

    create constraint(:thread_comments, :thread_comments_body_length,
             check: "length(body) <= 10000"
           )

    create table(:thread_comment_mentions, primary_key: false) do
      add :comment_id, references(:thread_comments, type: :text, on_delete: :delete_all),
        primary_key: true

      add :user_id, references(:users, type: :text, on_delete: :delete_all), primary_key: true
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:thread_comment_mentions, [:user_id])
  end
end
