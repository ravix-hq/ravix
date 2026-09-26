defmodule Ravix.Plans.Progress do
  @moduledoc "Plan counts from derived item statuses, never provider reads."

  def summarize(items) do
    counts = Enum.frequencies_by(items, & &1.status)
    done = Map.get(counts, :done, 0)
    total = length(items)
    blocked = Map.get(counts, :blocked, 0)

    %{
      done: done,
      wip: Map.get(counts, :in_progress, 0) + Map.get(counts, :in_review, 0),
      unstarted: Map.get(counts, :unassigned, 0) + Map.get(counts, :ready, 0) + blocked,
      blocked: blocked,
      total: total,
      percent: if(total == 0, do: 0, else: div(done * 100, total))
    }
  end
end
