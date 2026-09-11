defmodule Ravix.Repo.Migrations.PreviewsIntoColumns do
  @moduledoc """
  The preview record, as columns instead of one JSON document.

  `previews.row` held nineteen fields as a `jsonb` document, with `hostname`,
  `sprite` and `port` shadowed as real columns only so indexes could exist.
  It is the shape `preview-store.ts` kept, carried over whole.

  The cost was not the encoding. It was that the unit of write became the
  whole document: every writer read the record, changed a field, and wrote
  all nineteen back. `Ravix.Previews.touch/1` has a six-line comment about
  what that cost -- a `publish_ready` that committed between one writer's
  read and its write was reverted to `:starting`, and the gateway kept
  sending the reader back to the start page. The fix at the time was to
  re-read under `FOR UPDATE` and merge; with columns it is an `UPDATE` of the
  one field, and the lost update has nowhere to happen.

  ## Expand

  This adds the columns and backfills them. It does not drop `row`, and the
  release that goes with it writes both, so the previous release -- which
  reads `row` and nothing else -- keeps working throughout. Dropping `row` is
  a later migration, after this one has been everywhere.

  `config` stays `jsonb`. It is nil or a complete `{directory, command,
  readiness_path}`, which is one value rather than three columns that would
  each have to be checked against the others.

  The three integer times are milliseconds since the epoch, which is what
  `Ravix.Clock` answers and what every comparison against them is written in.
  """
  use Ecto.Migration

  @desired ~w(running stopped)
  @states ~w(stopped starting ready failed)

  def up do
    alter table(:previews) do
      add :service, :text
      add :config, :map
      add :applied_config, :text
      add :sandbox_id, :text
      add :desired, :text
      add :state, :text
      add :generation, :bigint
      add :last_activity, :bigint
      add :lease_until, :bigint
      add :started_at, :bigint
      add :error, :text
      add :logs, :text
      add :cleanup, :boolean
      add :stop_pending, :boolean
      add :unavailable, :text
    end

    flush()
    backfill()

    # Only now that every row has values. `desired` and `state` are a fixed
    # set and the database can say so, the way `tracks.origin_kind` does.
    alter table(:previews) do
      modify :service, :text, null: false
      modify :desired, :text, null: false
      modify :state, :text, null: false
      modify :generation, :bigint, null: false, default: 0
      modify :last_activity, :bigint, null: false, default: 0
      modify :lease_until, :bigint, null: false, default: 0
      modify :started_at, :bigint, null: false, default: 0
      modify :logs, :text, null: false, default: ""
      modify :cleanup, :boolean, null: false, default: false
      modify :stop_pending, :boolean, null: false, default: false
    end

    create constraint(:previews, :previews_desired, check: in_check("desired", @desired))
    create constraint(:previews, :previews_state, check: in_check("state", @states))
  end

  def down do
    drop constraint(:previews, :previews_desired)
    drop constraint(:previews, :previews_state)

    alter table(:previews) do
      remove :service
      remove :config
      remove :applied_config
      remove :sandbox_id
      remove :desired
      remove :state
      remove :generation
      remove :last_activity
      remove :lease_until
      remove :started_at
      remove :error
      remove :logs
      remove :cleanup
      remove :stop_pending
      remove :unavailable
    end
  end

  # Out of the document and into the columns, defaulting exactly as
  # `Ravix.Previews.Row.decode/1` defaulted before this migration removed it:
  # a missing count is zero, a missing flag is false, missing logs are empty,
  # and a word outside the set is the neutral member.
  #
  # Every document in this table was written by `Row.encode/1` and is snake
  # case; `decode/1` also accepted the camelCase spellings the TypeScript
  # wrote, but no TypeScript row ever reached `ravix.previews` -- the legacy
  # Bun tables are in `public` and were preserved rather than imported (ADR
  # 0002, README). The `COALESCE` on both spellings is kept anyway, because
  # it costs one line per field and the alternative is a silent zero.
  defp backfill do
    execute("""
    UPDATE #{prefix()}.previews SET
      service        = COALESCE(row->>'service', 'sy-' || COALESCE(hostname, '')),
      config         = CASE WHEN jsonb_typeof(row->'config') = 'object'
                            THEN jsonb_build_object(
                                   'directory',      row->'config'->>'directory',
                                   'command',        row->'config'->>'command',
                                   'readiness_path', #{either("row->'config'", "readiness_path", "readinessPath")}
                                 )
                            ELSE NULL END,
      applied_config = #{either("row", "applied_config", "appliedConfig")},
      sandbox_id     = #{either("row", "sandbox_id", "sandboxId")},
      desired        = CASE WHEN row->>'desired' IN (#{quoted(@desired)})
                            THEN row->>'desired' ELSE 'stopped' END,
      state          = CASE WHEN row->>'state' IN (#{quoted(@states)})
                            THEN row->>'state' ELSE 'stopped' END,
      generation     = COALESCE((row->>'generation')::bigint, 0),
      last_activity  = COALESCE((#{either("row", "last_activity", "lastActivity")})::bigint, 0),
      lease_until    = COALESCE((#{either("row", "lease_until", "leaseUntil")})::bigint, 0),
      started_at     = COALESCE((#{either("row", "started_at", "startedAt")})::bigint, 0),
      error          = row->>'error',
      logs           = COALESCE(row->>'logs', ''),
      cleanup        = COALESCE((row->>'cleanup')::boolean, false),
      stop_pending   = COALESCE((#{either("row", "stop_pending", "stopPending")})::boolean, false),
      unavailable    = row->>'unavailable'
    """)
  end

  # This server's spelling, or the one the TypeScript would have written.
  defp either(source, snake, camel),
    do: "COALESCE(#{source}->>'#{snake}', #{source}->>'#{camel}')"

  defp in_check(column, allowed), do: "#{column} IN (#{quoted(allowed)})"
  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
