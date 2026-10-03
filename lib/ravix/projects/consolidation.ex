defmodule Ravix.Projects.Consolidation do
  @moduledoc """
  Consolidates repository projects inside an explicit workspace, preserving their
  original provider resources. Dry by default. Apply only with serving instances
  stopped after the resource-aware release has deployed; this does not stop or
  close provider machines, tracks, worktrees, or conversations.
  """
  alias Ravix.Projects.Consolidation.Store

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace_id, opts \\ []) do
    # Assumed small pre-PMF table: local ravix_dev has zero projects; production
    # inventory was unavailable.
    # credo:disable-for-next-line Credo.Check.Design.TagTODO
    # TODO WHEN one workspace exceeds 1,000 projects,
    # measure the cutover transaction before considering batched processing.
    groups = Store.groups(workspace_id)

    if Keyword.get(opts, :apply, false) do
      apply_groups(workspace_id, groups)
    else
      {:ok, %{applied: false, groups: groups, merged: []}}
    end
  end

  defp apply_groups(workspace_id, groups) do
    Ravix.Repo.transaction(fn ->
      results =
        for group <- groups,
            donor_id <- group.donor_ids,
            do: merge!(workspace_id, group.canonical_id, donor_id)

      Store.finish_workspace(workspace_id)
      %{applied: true, groups: groups, merged: results}
    end)
  end

  defp merge!(workspace_id, canonical_id, donor_id) do
    case Store.merge(workspace_id, canonical_id, donor_id) do
      {:ok, result} -> result
      {:error, reason} -> Ravix.Repo.rollback(reason)
    end
  end
end
