defmodule Ravix.Plans.Prompt do
  @moduledoc "Pure assignment prompt assembly. Siblings describe boundaries, not instructions to execute."
  def build(plan, item, siblings) do
    coverage =
      siblings
      |> Enum.reject(&(&1.id == item.id))
      |> Enum.map_join("\n", fn sibling ->
        "- #{sibling.title} (track: #{sibling.track_id || "unassigned"}): #{sibling.brief}"
      end)

    """
    Project plan: #{plan.title}

    #{plan.summary}

    Your item: #{item.title}
    #{item.brief}

    Acceptance notes:
    #{item.acceptance}

    Sibling work and scope boundaries:
    #{coverage}

    Stay within this item's scope. Other tracks may be working in parallel; leave their work alone.
    Expect to rebase onto main. Push your branch and open a draft PR with validation and limitations.
    Do not merge. Notes and agent claims do not mark this item done; only a merged PR does.
    """
  end
end
