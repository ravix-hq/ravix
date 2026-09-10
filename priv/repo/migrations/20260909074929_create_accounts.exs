defmodule Ravix.Repo.Migrations.CreateAccounts do
  @moduledoc """
  Who signed in, their sessions, and the OAuth round-trip state.

  Sessions are stored as hashes, never as the token itself: a copy of this
  database is then not a set of live sessions.
  """
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :text, primary_key: true
      add :github_id, :text, null: false
      add :login, :text, null: false
      add :name, :text
      add :avatar_url, :text
      add :token_enc, :text
      add :created_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
    end

    create unique_index(:users, [:github_id])

    create table(:sessions, primary_key: false) do
      add :token_hash, :text, primary_key: true

      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false

      add :created_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create index(:sessions, [:user_id], name: :sessions_user)

    # Short-lived signed state for the two GitHub round trips. Rows are
    # deleted on use and swept on age, so a replayed callback finds nothing.
    create table(:oauth_states, primary_key: false) do
      add :state, :text, primary_key: true
      add :kind, :text, null: false
      add :redirect, :text
      add :created_at, :utc_datetime_usec, null: false
    end
  end
end
