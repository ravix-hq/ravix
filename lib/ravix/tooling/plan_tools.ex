defmodule Ravix.Tooling.PlanTools do
  @moduledoc "Plan protocol operations. Actor identity comes from authentication, never arguments."
  alias Ravix.Plans
  alias Ravix.Plans.Assignment

  def execute(p, "create_plan", a) do
    with {:ok, plan} <- Plans.create(p.user, a["project_id"], a, actor(p)),
         do: {:ok, Plans.public_plan(plan)}
  end

  def execute(p, "get_plan", a) do
    with {:ok, %{plan: plan, items: items}} <- Plans.get(p.user, a["plan_id"]),
         do: {:ok, Map.put(Plans.public_plan(plan), :items, items)}
  end

  def execute(p, "list_plans", a) do
    with {:ok, plans} <- Plans.list(p.user, a["project_id"]),
         do: {:ok, %{items: Enum.map(plans, &Plans.public_plan/1)}}
  end

  def execute(p, "update_plan", a) do
    with {:ok, plan} <- Plans.update(p.user, a["plan_id"], a["expected_version"], a, actor(p)),
         do: {:ok, Plans.public_plan(plan)}
  end

  def execute(p, "assign_items", a),
    do: Assignment.assign(p.user, p, a["plan_id"], a["assignments"], a["request_id"])

  def execute(p, "note_item", a) do
    with {:ok, note} <- Plans.note(p.user, a["item_id"], a["body"], actor(p)),
         do:
           {:ok, Map.take(note, [:id, :item_id, :body, :created_by_login, :created_by_track_id])}
  end

  def recheck(p, name, a, _) when name in ["create_plan", "list_plans"],
    do: access(Plans.list(p.user, a["project_id"]))

  def recheck(p, "note_item", a, _), do: Plans.check_item(p.user, a["item_id"])
  def recheck(p, _, a, _), do: access(Plans.access(p.user, a["plan_id"]))
  defp access({:ok, _}), do: :ok
  defp access({:ok, _, _}), do: :ok
  defp access(error), do: error
  defp actor(p), do: Map.get(p, :actor, :person)
end
