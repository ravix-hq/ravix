defmodule Ravix.Workspaces.Backfill do
  @moduledoc """
  The personal-workspace backfill (ADR 0009, phase 2).

  Gives every user a personal workspace with themselves as its owner, and
  fills the two project fields whose meaning is the same as a legacy
  column's (`created_by_user_id`, `normalized_repo_full_name`). It does not
  move any project into a workspace and admits nobody to anything: that is
  an explicit, consented admission in a later phase.

  Its last step (RAV-69) connects to each workspace the GitHub App
  installations its own live projects already clone through, so the
  workspace's GitHub section and catalog agree with the projects it holds.
  Never a personal account's installation to a team workspace, and never
  one somebody revoked; see `Ravix.Workspaces.Store.attach_backing_installations/2`.

  Resumable by construction rather than by a checkpoint. Each batch selects
  only what is still missing (see `Ravix.Workspaces.Store`), so a run cut
  off halfway, a second run, a run on another instance at the same moment
  and a run after an older release has inserted more rows all pick up
  exactly the remainder. The unique personal-workspace index and
  `ON CONFLICT DO NOTHING` make the concurrent case safe as well as correct.

  `Ravix.Release.migrate/0` runs it after every migration, so each deploy
  reconciles whatever the previous release wrote while this one rolled out.
  """

  require Logger

  alias Ravix.Workspaces.Store

  @batch 500
  # Per batch. A batch of #{@batch} rows takes milliseconds; one that takes
  # this long is contending with the serving release and should give way.
  @statement_timeout_ms 15_000

  @typedoc "How many rows each step wrote in this run."
  @type result :: %{
          workspaces: non_neg_integer(),
          memberships: non_neg_integer(),
          projects: non_neg_integer(),
          installations: non_neg_integer()
        }

  @doc """
  Run every step until it has nothing left, or until `:max_batches` batches
  per step (for a bounded run; the next one resumes). `:batch_size` defaults
  to #{@batch}. Each batch is its own transaction, bounded by
  `:statement_timeout_ms` (default #{@statement_timeout_ms}).
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    batch = Keyword.get(opts, :batch_size, @batch)
    max = Keyword.get(opts, :max_batches, :infinity)
    timeout = Keyword.get(opts, :statement_timeout_ms, @statement_timeout_ms)
    step = &bounded(&1, batch, timeout)

    result = %{
      workspaces: drain(step.(&Store.insert_personal_workspaces/1), max),
      memberships: drain(step.(&Store.insert_owner_memberships/1), max),
      projects: drain(step.(&Store.fill_project_attribution/1), max),
      installations: drain(step.(&Store.attach_backing_installations/1), max)
    }

    Logger.info("workspace backfill: #{inspect(result)}")
    result
  end

  # One batch of `fun`, in its own transaction under the statement timeout.
  defp bounded(fun, batch, timeout), do: fn -> Store.bounded(fn -> fun.(batch) end, timeout) end

  defp drain(step, max, total \\ 0, done \\ 0)
  defp drain(_step, max, total, max), do: total

  defp drain(step, max, total, done) do
    case step.() do
      0 -> total
      count -> drain(step, max, total + count, done + 1)
    end
  end
end
