defmodule Ravix.Repo.Migrations.AddThreads do
  use Ecto.Migration

  def up do
    create table(:threads, primary_key: false) do
      add :id, :text, primary_key: true
      add :track_id, references(:tracks, type: :text, on_delete: :delete_all), null: false
      add :conversation_id, :text
      add :title, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec
    end

    create index(:threads, [:track_id, :created_at])
    create unique_index(:threads, [:conversation_id])
    create unique_index(:threads, [:track_id, :id])

    # The default thread has the track's ID. The trigger covers writes by
    # the previous release throughout the rolling deploy, including attaches.
    execute """
    CREATE FUNCTION ravix.sync_default_thread() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO ravix.threads (id, track_id, conversation_id, title, created_at, closed_at)
      VALUES (NEW.id, NEW.id, NEW.conversation_id, 'Default', NEW.created_at, NEW.closed_at)
      ON CONFLICT (id) DO UPDATE SET conversation_id = EXCLUDED.conversation_id,
        closed_at = EXCLUDED.closed_at;
      RETURN NEW;
    END $$
    """

    execute """
    CREATE TRIGGER tracks_default_thread AFTER INSERT OR UPDATE OF conversation_id, closed_at
    ON ravix.tracks FOR EACH ROW EXECUTE FUNCTION ravix.sync_default_thread()
    """

    execute """
    INSERT INTO ravix.threads (id, track_id, conversation_id, title, created_at, closed_at)
    SELECT id, id, conversation_id, 'Default', created_at, closed_at FROM ravix.tracks
    """

    alter table(:prompt_queue) do
      add :thread_id, :text
    end

    execute "UPDATE ravix.prompt_queue SET thread_id = track_id"

    execute """
    ALTER TABLE ravix.prompt_queue ADD CONSTRAINT prompt_queue_thread_fkey
    FOREIGN KEY (track_id, thread_id) REFERENCES ravix.threads(track_id, id) ON DELETE CASCADE
    """

    execute """
    CREATE FUNCTION ravix.default_prompt_thread() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      NEW.thread_id := COALESCE(NEW.thread_id, NEW.track_id);
      RETURN NEW;
    END $$
    """

    execute """
    CREATE TRIGGER prompt_default_thread BEFORE INSERT ON ravix.prompt_queue
    FOR EACH ROW EXECUTE FUNCTION ravix.default_prompt_thread()
    """

    alter table(:prompt_queue) do
      modify :thread_id, :text, null: false
    end

    create index(:prompt_queue, [:thread_id, :sequence],
             name: :prompt_queue_thread_heads,
             where: "status IN ('queued', 'sending', 'failed', 'unconfirmed')"
           )

    create table(:thread_reads, primary_key: false) do
      add :thread_id, references(:threads, type: :text, on_delete: :delete_all), primary_key: true
      add :user_id, references(:users, type: :text, on_delete: :delete_all), primary_key: true
      add :seen_at, :utc_datetime_usec, null: false
    end

    execute """
    INSERT INTO ravix.thread_reads (thread_id, user_id, seen_at)
    SELECT track_id, user_id, seen_at FROM ravix.track_reads
    """

    execute """
    CREATE FUNCTION ravix.sync_default_read() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO ravix.thread_reads (thread_id, user_id, seen_at)
      VALUES (NEW.track_id, NEW.user_id, NEW.seen_at)
      ON CONFLICT (thread_id, user_id) DO UPDATE SET seen_at = EXCLUDED.seen_at;
      RETURN NEW;
    END $$
    """

    execute """
    CREATE TRIGGER track_default_read AFTER INSERT OR UPDATE ON ravix.track_reads
    FOR EACH ROW EXECUTE FUNCTION ravix.sync_default_read()
    """
  end

  def down do
    execute "DROP TRIGGER track_default_read ON ravix.track_reads"
    execute "DROP FUNCTION ravix.sync_default_read()"
    drop table(:thread_reads)
    execute "DROP TRIGGER prompt_default_thread ON ravix.prompt_queue"
    execute "DROP FUNCTION ravix.default_prompt_thread()"
    drop index(:prompt_queue, [:thread_id, :sequence], name: :prompt_queue_thread_heads)
    alter table(:prompt_queue), do: remove(:thread_id)
    execute "DROP TRIGGER tracks_default_thread ON ravix.tracks"
    execute "DROP FUNCTION ravix.sync_default_thread()"
    drop table(:threads)
  end
end
