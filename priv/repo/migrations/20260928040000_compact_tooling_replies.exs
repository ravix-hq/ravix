defmodule Ravix.Repo.Migrations.CompactToolingReplies do
  use Ecto.Migration

  def change do
    alter table(:tooling_tasks) do
      add :reply_compacted, :boolean, null: false, default: false
      add :reply_size, :integer, null: false, default: 0
      add :reply_bytes, :integer, null: false, default: 0
      add :failure_evidence, :map, null: false, default: %{}
    end

    create table(:tooling_reply_chunks, primary_key: false) do
      add :task_id, references(:tooling_tasks, type: :text, on_delete: :delete_all),
        primary_key: true

      add :cursor, :bigint, primary_key: true
      add :body, :text, null: false
    end

    # An overlapping old release may still write a journal. Mark it for conversion
    # again; never trim evidence while that release is still consuming it.
    execute """
            CREATE FUNCTION ravix.invalidate_tooling_reply() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF NEW.reply_events IS DISTINCT FROM OLD.reply_events AND
                 (NEW.reply_events IS NULL OR cardinality(NEW.reply_events) > 0) THEN
                NEW.reply_compacted := false;
              END IF;
              RETURN NEW;
            END $$
            """,
            "DROP FUNCTION ravix.invalidate_tooling_reply()"

    execute """
            CREATE TRIGGER tooling_reply_legacy_write BEFORE UPDATE OF reply_events ON ravix.tooling_tasks
            FOR EACH ROW EXECUTE FUNCTION ravix.invalidate_tooling_reply()
            """,
            "DROP TRIGGER tooling_reply_legacy_write ON ravix.tooling_tasks"

    create index(:tooling_tasks, [:id],
             where: "reply_compacted = false",
             name: :tooling_reply_cleanup
           )
  end
end
