defmodule Ravix.Repo.Migrations.ExpandPreviewAgentGrantThread do
  @moduledoc """
  Expand step for the agent grant's thread. The column is added nullable and
  backfilled from the grant document, because the release this migration runs
  beside is still serving and still inserts grants without it. Reads therefore
  stay on `COALESCE(thread_id, row->>'thread_id', track_id)` until every
  instance sets the column.

  `preview_agent_grants_thread`, the functional unique index on
  `(track_id, COALESCE(row->>'thread_id', track_id))`, is deliberately left in
  place: it is the only index that covers both shapes while the deploy rolls.
  A unique index on `(track_id, thread_id)` is not created here. Postgres
  treats NULLs as distinct, so it would silently enforce nothing for the rows
  the previous release writes while claiming to protect them. It belongs in
  the release that sets `thread_id` NOT NULL.
  """
  use Ecto.Migration

  def up do
    alter table(:preview_agent_grants) do
      add :thread_id, :text
    end

    flush()

    execute(
      "UPDATE #{prefix()}.preview_agent_grants SET thread_id = COALESCE(row->>'thread_id', track_id)"
    )
  end

  def down do
    alter table(:preview_agent_grants) do
      remove :thread_id
    end
  end
end
