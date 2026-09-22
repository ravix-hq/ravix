defmodule Ravix.Repo.Migrations.DropLegacyColumns do
  @moduledoc """
  Contract for the expand migrations `PreviewsIntoColumns` and
  `PromptQueuePayloadAsJson`. Those migrations are in this release history and
  must have run in production before this migration is applied.

  The down direction recreates the columns from the replacement fields, but
  cannot restore the original JSON formatting or any unknown legacy keys.
  """
  use Ecto.Migration

  def up do
    alter table(:preview_agent_grants), do: add(:thread_id, :text)
    flush()

    execute(
      "UPDATE #{prefix()}.preview_agent_grants SET thread_id = COALESCE(row->>'thread_id', track_id)"
    )

    alter table(:preview_agent_grants), do: modify(:thread_id, :text, null: false)
    drop unique_index(:preview_agent_grants, [:track_id], name: :preview_agent_grants_thread)

    create unique_index(:preview_agent_grants, [:track_id, :thread_id],
             name: :preview_agent_grants_thread
           )

    alter table(:previews), do: remove(:row)
    alter table(:prompt_queue), do: remove(:payload)
  end

  def down do
    drop unique_index(:preview_agent_grants, [:track_id, :thread_id],
           name: :preview_agent_grants_thread
         )

    create unique_index(
             :preview_agent_grants,
             ["track_id", "(COALESCE(row->>'thread_id', track_id))"],
             name: :preview_agent_grants_thread
           )

    alter table(:preview_agent_grants), do: remove(:thread_id)
    alter table(:previews), do: add(:row, :map)
    alter table(:prompt_queue), do: add(:payload, :text)
    flush()

    execute("""
    UPDATE #{prefix()}.previews SET row = jsonb_build_object(
      'track_id', track_id, 'hostname', hostname, 'service', service,
      'sprite', sprite, 'port', port, 'sandbox_id', sandbox_id,
      'config', config, 'applied_config', applied_config, 'desired', desired,
      'state', state, 'generation', generation, 'last_activity', last_activity,
      'lease_until', lease_until, 'started_at', started_at, 'error', error,
      'logs', logs, 'cleanup', cleanup, 'stop_pending', stop_pending,
      'unavailable', unavailable)
    """)

    execute("UPDATE #{prefix()}.prompt_queue SET payload = COALESCE(body::text, '')")
  end
end
