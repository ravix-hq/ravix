defmodule Ravix.Tooling.Catalog do
  @moduledoc "The external tool schemas and their required scopes."

  def tools do
    [
      tool("list_projects", "List projects you can access.", "projects:read", pagination(), []),
      tool(
        "list_repositories",
        "List repositories available for project creation.",
        "projects:read",
        Map.put(pagination(), "installation_id", integer()),
        []
      ),
      tool(
        "create_project",
        "Create a project using your connected agent subscription.",
        "projects:write",
        %{
          "name" => string(100),
          "repo" => string(200),
          "installation_id" => integer(),
          "request_id" => string(100)
        },
        ["request_id"]
      ),
      tool(
        "get_project_settings",
        "Read settings of a project you own. Secret values are never returned.",
        "projects:write",
        %{"project_id" => string()},
        ["project_id"]
      ),
      tool(
        "update_project_settings",
        "Update owned project settings; setup scripts and instructions can execute code.",
        "projects:write",
        %{"project_id" => string(), "settings" => settings(), "request_id" => string(100)},
        ["project_id", "settings", "request_id"]
      ),
      tool(
        "list_tracks",
        "List tracks you can access in a project.",
        "tracks:read",
        Map.put(pagination(), "project_id", string()),
        ["project_id"]
      ),
      tool(
        "get_track",
        "Read a track's state, branch and browser link.",
        "tracks:read",
        %{"track_id" => string()},
        ["track_id"]
      ),
      tool(
        "create_track",
        "Open a track and its worktree on a project.",
        "tracks:write",
        %{
          "project_id" => string(),
          "title" => string(200),
          "origin" => origin(),
          "request_id" => string(100)
        },
        ["project_id", "request_id"]
      ),
      tool(
        "send_prompt",
        "Queue a prompt durably. Reuse request_id only to retry the same prompt; poll get_task for completion.",
        "tracks:write",
        %{"track_id" => string(), "prompt" => string(100_000), "request_id" => string(100)},
        ["track_id", "prompt", "request_id"]
      ),
      tool(
        "get_task",
        "Read the state and reply of a task submitted by this client.",
        "tracks:read",
        %{"task_id" => string()},
        ["task_id"]
      ),
      tool(
        "cancel_task",
        "Cancel this client's queued task. Running tasks cannot be safely interrupted.",
        "tracks:cancel",
        %{"task_id" => string()},
        ["task_id"]
      ),
      tool(
        "read_track",
        "Read a bounded page of track events. Pass next_cursor as after to continue.",
        "tracks:read",
        %{
          "track_id" => string(),
          "after" => integer(),
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
        },
        ["track_id"]
      )
    ]
  end

  def find(name), do: Enum.find(tools(), &(&1.name == name))
  def public(tool), do: Map.drop(tool, [:scope])

  def validate(value, %{"type" => "object", "properties" => properties} = schema)
      when is_map(value) do
    Enum.all?(Map.get(schema, "required", []), &Map.has_key?(value, &1)) and
      Enum.all?(value, fn {k, v} -> Map.has_key?(properties, k) and validate(v, properties[k]) end)
  end

  def validate(value, %{"type" => "object"}) when is_map(value), do: true

  def validate(value, %{"type" => "string"} = schema) when is_binary(value),
    do:
      byte_size(value) <= schema["maxLength"] and
        byte_size(value) >= Map.get(schema, "minLength", 1) and enum?(value, schema)

  def validate(value, %{"type" => "integer"} = schema) when is_integer(value),
    do:
      value >= Map.get(schema, "minimum", 0) and
        value <= Map.get(schema, "maximum", 9_007_199_254_740_991)

  def validate(_, _), do: false

  defp enum?(value, %{"enum" => values}), do: value in values
  defp enum?(_, _), do: true
  defp string(max \\ 200), do: %{"type" => "string", "maxLength" => max}
  defp integer, do: %{"type" => "integer", "minimum" => 0}

  defp object(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  defp tool(name, description, scope, properties, required) do
    %{
      name: name,
      description: description,
      scope: scope,
      inputSchema: object(properties, required),
      annotations: %{
        readOnlyHint: String.ends_with?(scope, ":read") or name == "get_project_settings",
        destructiveHint: scope in ["projects:write", "tracks:cancel"],
        openWorldHint: true
      }
    }
  end

  defp pagination do
    %{"after" => string(), "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}}
  end

  defp settings do
    object(
      %{
        "name" => string(100),
        "runtime" => string(),
        "model" => string(),
        "instructions" => Map.put(string(100_000), "minLength", 0),
        "setup_script" => Map.put(string(100_000), "minLength", 0),
        "packages" => %{"type" => "object"}
      },
      []
    )
  end

  defp origin do
    object(
      %{
        "kind" => Map.put(string(), "enum", ["blank", "branch", "pr", "issue"]),
        "base" => string(),
        "number" => integer(),
        "title" => string(200)
      },
      ["kind"]
    )
  end
end
