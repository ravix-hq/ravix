defmodule Ravix.Repo.Migrations.CreatePromptQueue do
  @moduledoc """
  Accepted prompts awaiting delivery: work Ravix owes the caller, which
  must outlive the browser that submitted it.
  """
  use Ecto.Migration

  def change do
    create table(:prompt_queue, primary_key: false) do
      add :sequence, :identity, primary_key: true
      add :id, :text, null: false

      add :track_id, references(:tracks, type: :text, on_delete: :delete_all), null: false

      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false

      add :author_login, :text, null: false
      add :payload, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :status, :text, null: false, default: "queued"
      add :error, :text
    end

    create unique_index(:prompt_queue, [:id])
    create index(:prompt_queue, [:track_id, :status, :sequence], name: :prompt_queue_track)
  end
end
