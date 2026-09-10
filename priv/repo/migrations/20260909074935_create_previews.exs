defmodule Ravix.Repo.Migrations.CreatePreviews do
  @moduledoc """
  Previews: per-project defaults, one row per track, and the two kinds of
  grant that let a browser or the agent reach one.

  Additive tables; the unique index owns port allocation, including across
  connections. The TypeScript declared no ON DELETE clause on the track and
  user references here, and none is added: a track with a preview is not
  deleted, it is closed.
  """
  use Ecto.Migration

  def change do
    create table(:preview_defaults, primary_key: false) do
      add :project_id, references(:projects, type: :text), primary_key: true
      add :config, :map, null: false
    end

    create table(:previews, primary_key: false) do
      add :track_id, references(:tracks, type: :text), primary_key: true
      add :hostname, :text, null: false
      add :sprite, :text
      add :port, :integer
      add :row, :map, null: false
    end

    create unique_index(:previews, [:hostname])

    create unique_index(:previews, [:sprite, :port],
             name: :preview_ports,
             where: "sprite IS NOT NULL"
           )

    create table(:preview_grants, primary_key: false) do
      add :hash, :text, primary_key: true
      add :track_id, references(:tracks, type: :text), null: false

      add :session_hash,
          references(:sessions, type: :text, column: :token_hash, on_delete: :delete_all),
          null: false

      add :expires, :bigint, null: false
      add :kind, :text, null: false
    end

    create table(:preview_agent_grants, primary_key: false) do
      add :hash, :text, primary_key: true
      add :track_id, references(:tracks, type: :text), null: false
      add :user_id, references(:users, type: :text), null: false
      add :expires, :bigint, null: false
      add :row, :map, null: false
    end

    create unique_index(:preview_agent_grants, [:track_id])
  end
end
