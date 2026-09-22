defmodule Ravix.Tooling.PlanCatalog do
  @moduledoc "Typed plan schemas, including explicit paid assignment."
  def tools do
    [
      tool(
        "create_plan",
        "Create a project plan; creating a plan does not start agents.",
        "plans:write",
        %{
          "project_id" => string(),
          "title" => string(),
          "summary" => text(100_000),
          "items" => items()
        },
        ~w(project_id title items)
      ),
      tool(
        "get_plan",
        "Read a project plan with derived status and track links. Track shares do not grant plan access.",
        "plans:read",
        %{"plan_id" => string()},
        ~w(plan_id)
      ),
      tool(
        "list_plans",
        "List a project's plans, including archived plans.",
        "plans:read",
        %{"project_id" => string()},
        ~w(project_id)
      ),
      tool(
        "update_plan",
        "Edit a plan at expected_version. Items replaces the ordered list; assigned items must remain unchanged.",
        "plans:write",
        %{
          "plan_id" => string(),
          "expected_version" => %{"type" => "integer", "minimum" => 1},
          "title" => string(),
          "summary" => text(100_000),
          "archived" => %{"type" => "boolean"},
          "items" => items()
        },
        ~w(plan_id expected_version)
      ),
      tool(
        "assign_items",
        "People only: open or attach tracks and prompt them, spending the project owner's subscription. Requires plans:write and tracks:write. Retry the same request_id to retrieve receipts.",
        "plans:write",
        %{
          "plan_id" => string(),
          "request_id" => string(100),
          "assignments" =>
            array(object(%{"item_id" => string(100), "track_id" => string()}, ~w(item_id)))
        },
        ~w(plan_id request_id assignments)
      ),
      tool(
        "note_item",
        "Append an observation to an accessible item. Notes cannot set status.",
        "plans:write",
        %{"item_id" => string(100), "body" => string(10_000)},
        ~w(item_id body)
      )
    ]
  end

  defp items do
    array(
      object(
        %{
          "id" => string(100),
          "title" => string(),
          "brief" => text(30_000),
          "acceptance" => text(10_000),
          "dependencies" => array(string(100))
        },
        ~w(title)
      )
    )
  end

  defp tool(name, description, scope, properties, required),
    do: %{
      name: name,
      description: description,
      scope: scope,
      inputSchema: object(properties, required),
      annotations: %{
        readOnlyHint: scope == "plans:read",
        destructiveHint: name == "assign_items",
        openWorldHint: true
      }
    }

  defp string(max \\ 200), do: %{"type" => "string", "maxLength" => max}
  defp text(max), do: Map.put(string(max), "minLength", 0)
  defp array(items), do: %{"type" => "array", "items" => items, "maxItems" => 100}

  defp object(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
end
