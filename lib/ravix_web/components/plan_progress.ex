defmodule RavixWeb.PlanProgress do
  @moduledoc "Shared textual and visual plan progress."
  use Phoenix.Component

  attr :progress, :map, default: nil
  attr :label, :string, default: "Plan completion"

  def summary(assigns) do
    ~H"""
    <span :if={!@progress} class="plan-progress-placeholder" role="status">Loading progress…</span>
    <span :if={@progress} class="plan-progress">
      <progress value={@progress.percent} max="100" aria-label={@label}>{@progress.percent}%</progress>
      <span>{@progress.percent}% complete</span>
      <span>{@progress.wip} WIP</span>
      <span>{@progress.unstarted} unstarted<span :if={@progress.blocked > 0}> ({@progress.blocked} blocked)</span></span>
    </span>
    """
  end
end
