defmodule Ravix.Repo.Migrations.AddPromptQueueClaimedAt do
  @moduledoc """
  When a row was claimed for delivery.

  `:sending` on its own cannot tell "a server died holding this" from "a task
  is POSTing it right now": recovery had to assume the first, which strands a
  row forever when the claim outlives its task, and replays one that is still
  in flight when it does not. The timestamp is what makes the difference
  answerable.
  """
  use Ecto.Migration

  def change do
    alter table(:prompt_queue) do
      add :claimed_at, :utc_datetime_usec
    end
  end
end
