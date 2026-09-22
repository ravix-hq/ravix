defmodule Ravix.Repo.Migrations.IndexPromptQueueLiveRows do
  @moduledoc """
  The two reads the prompt queue's sweep makes, answered from indexes that
  hold only the rows they are about.

  Every instance sweeps the queue every two seconds, and a sweep asks two
  questions: the first live row of every track, and every `sending` row
  whose claim has gone stale. The only index was `(track_id, status,
  sequence)`, which serves a lookup on one track and neither of these:
  both scanned the whole table, and the whole table is nearly all delivered
  rows, which every sweep read and discarded. That is one scan per question
  per instance per two seconds, growing with everything ever sent.

    * `prompt_queue_live_heads` is `(track_id, sequence)` over the four live
      statuses, which is `DISTINCT ON (track_id) ... ORDER BY track_id,
      sequence` in one pass. The set is spelled out here and in
      `Ravix.PromptQueue.Store`, which checks it against
      `Ravix.PromptQueue.Item.statuses/0` at compile time, because the
      planner uses a partial index only when it can prove the query's
      predicate implies the index's, and the store now writes the same
      `status IN (...)` for that reason.
    * `prompt_queue_sending_claims` is `(claimed_at)` over `sending` rows
      only. There are seldom any, so recovery reads almost nothing.

  Neither is built `CONCURRENTLY`: no migration here runs outside the
  migrator's transaction, and at this table's size a plain `CREATE INDEX`
  holds its write lock for well under a second. Safe while the previous
  release is still serving (expand/contract): an index is invisible to a
  release that does not ask for it. The old `(track_id, status, sequence)`
  index stays, because a track's own lookups (a panel's summaries, a cancel
  of everything on it) still go through it.
  """
  use Ecto.Migration

  @live ~w(queued sending failed unconfirmed)

  def up do
    create index(:prompt_queue, [:track_id, :sequence],
             name: :prompt_queue_live_heads,
             where: "status IN (#{Enum.map_join(@live, ", ", &"'#{&1}'")})"
           )

    create index(:prompt_queue, [:claimed_at],
             name: :prompt_queue_sending_claims,
             where: "status = 'sending'"
           )
  end

  def down do
    drop index(:prompt_queue, [:claimed_at], name: :prompt_queue_sending_claims)
    drop index(:prompt_queue, [:track_id, :sequence], name: :prompt_queue_live_heads)
  end
end
