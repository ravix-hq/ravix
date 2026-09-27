defmodule Ravix.Repo.Migrations.ExpandTrackSandboxes do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :sandbox_layout, :text, null: false, default: "shared"
      add :sandbox_id, :text
      add :sandbox_generation, :bigint, null: false, default: 0
      add :sandbox_state, :text
      add :vault_id, :text
    end

    create constraint(:tracks, :tracks_sandbox_layout,
             check: "sandbox_layout IN ('shared', 'dedicated')"
           )

    create constraint(:tracks, :tracks_sandbox_generation, check: "sandbox_generation >= 0")

    create constraint(:tracks, :tracks_sandbox_state,
             check:
               "sandbox_state IN ('provisioning', 'ready', 'failed', 'closing', 'terminated')"
           )

    create unique_index(:tracks, [:sandbox_id],
             name: :tracks_dedicated_sandbox_id,
             where: "sandbox_layout = 'dedicated' AND sandbox_id IS NOT NULL"
           )

    # Resource IDs are retained even after the track is archived. Deleting a
    # track must not silently discard outstanding cleanup obligations.
    create table(:track_sandbox_operations, primary_key: false) do
      add :id, :text, primary_key: true
      add :track_id, references(:tracks, type: :text, on_delete: :restrict), null: false
      add :generation, :bigint, null: false
      add :action, :text, null: false
      add :attempts, :integer, null: false, default: 0
      add :revision, :bigint, null: false, default: 1
      add :resource_ids, :map, null: false, default: %{}
      add :error, :map
      add :cleanup, :map, null: false, default: %{}
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:track_sandbox_operations, [:track_id, :generation, :action])
    create index(:track_sandbox_operations, [:inserted_at], where: "completed_at IS NULL")

    create constraint(:track_sandbox_operations, :sandbox_operations_action,
             check: "action IN ('open', 'close', 'rebuild')"
           )

    create constraint(:track_sandbox_operations, :sandbox_operations_counters,
             check: "generation > 0 AND attempts >= 0 AND revision > 0"
           )
  end
end
