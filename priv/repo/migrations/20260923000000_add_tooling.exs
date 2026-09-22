defmodule Ravix.Repo.Migrations.AddTooling do
  use Ecto.Migration

  def change do
    create table(:tooling_clients, primary_key: false) do
      add :id, :text, primary_key: true
      add :name, :text, null: false
      add :redirect_uris, {:array, :text}, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:tooling_grants, primary_key: false) do
      add :id, :text, primary_key: true
      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :client_id, references(:tooling_clients, type: :text), null: false
      add :resource, :text, null: false
      add :scopes, {:array, :text}, null: false
      add :revoked_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:tooling_credentials, primary_key: false) do
      add :hash, :text, primary_key: true
      add :grant_id, references(:tooling_grants, type: :text, on_delete: :delete_all), null: false
      add :kind, :text, null: false
      add :redirect_uri, :text
      add :challenge, :text
      add :used_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
    end

    create index(:tooling_grants, [:user_id])
    create index(:tooling_credentials, [:grant_id])

    create table(:tooling_receipts, primary_key: false) do
      add :id, :text, primary_key: true
      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :client_id, references(:tooling_clients, type: :text), null: false
      add :operation, :text, null: false
      add :fingerprint, :text, null: false
      add :result, :map
      timestamps(type: :utc_datetime_usec)
    end

    create table(:tooling_tasks, primary_key: false) do
      add :id, :text, primary_key: true
      add :user_id, references(:users, type: :text, on_delete: :delete_all), null: false
      add :client_id, references(:tooling_clients, type: :text), null: false
      add :track_id, references(:tracks, type: :text, on_delete: :delete_all), null: false
      add :fingerprint, :text, null: false
      add :state, :text, null: false, default: "TASK_STATE_SUBMITTED"
      add :turn_id, :text
      add :cursor, :bigint
      add :result, :text, null: false, default: ""
      timestamps(type: :utc_datetime_usec)
    end

    create index(:tooling_tasks, [:user_id, :client_id, :updated_at, :id])
  end
end
