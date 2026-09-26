defmodule Ravix.Repo.Migrations.AddTrackSetup do
  use Ecto.Migration

  def change do
    # Existing tracks are verified too: opened_at used to mean only accepted.
    alter table(:tracks) do
      add :setup_state, :text, null: false, default: "pending"
      add :setup_attempts, :integer, null: false, default: 0
      add :setup_request_id, :text
      add :setup_started_at, :utc_datetime_usec
      add :setup_retry_at, :utc_datetime_usec
      add :setup_error, :text
      add :setup_lease, :text
      add :setup_lease_until, :utc_datetime_usec
    end

    create index(:tracks, [:setup_state], where: "closed_at IS NULL AND setup_state != 'ready'")

    # Old releases still claim without a setup predicate during rolling deploys.
    # Suppress that UPDATE (zero rows claimed), preserving the old worker's
    # existing lost-claim path until every instance runs the new gate.
    execute """
            CREATE FUNCTION ravix.gate_prompt_setup() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF NOT EXISTS (SELECT 1 FROM ravix.tracks
                             WHERE id = NEW.track_id AND setup_state = 'ready' AND closed_at IS NULL) THEN
                RETURN NULL;
              END IF;
              RETURN NEW;
            END;
            $$
            """,
            "DROP FUNCTION IF EXISTS ravix.gate_prompt_setup()"

    execute """
            CREATE TRIGGER prompt_setup_gate BEFORE UPDATE OF status ON ravix.prompt_queue
            FOR EACH ROW WHEN (OLD.status = 'queued' AND NEW.status = 'sending')
            EXECUTE FUNCTION ravix.gate_prompt_setup()
            """,
            "DROP TRIGGER IF EXISTS prompt_setup_gate ON ravix.prompt_queue"
  end
end
