defmodule Ravix.Tooling.Catalog do
  @moduledoc "The external tool schemas and their required scopes."

  alias Ravix.Tooling.PlanCatalog

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
        "Create a project using a connected credential. Optional runtime is claude or codex; defaults to your account agent, then the catalog default. Connect that agent first or receive agent_not_connected.",
        "projects:write",
        %{
          "name" => string(100),
          "repo" => string(200),
          "installation_id" => integer(),
          "runtime" => %{"type" => "string", "enum" => ["claude", "codex"]},
          "request_id" => string(100)
        },
        ["request_id"]
      ),
      tool(
        "get_project_settings",
        "Read settings of a project you own. Includes readable env_vars values. Secret values are never returned.",
        "projects:write",
        %{"project_id" => string()},
        ["project_id"]
      ),
      tool(
        "update_project_settings",
        "Update owned project settings; setup scripts and instructions can execute code. env_vars unconditionally replaces all readable variables (empty object clears them; no stale-map check), applies to the next conversation, and rejects secret names and provider auth names. Limit 100 variables, 200 bytes per name, 16 KiB per value.",
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
        "Open a track. Without runtime, use your preferred agent/model when the project payer can use it, otherwise the project default. Supply branch_name (or the compatibility alias title) without the fixed ravix/ prefix; returns the full branch. PR origins keep their existing branch; supply the PR number to resolve its head from GitHub.",
        "tracks:write",
        %{
          "project_id" => string(),
          "runtime" => %{"type" => "string", "enum" => ["claude", "codex"]},
          "model" => string(),
          "branch_name" => %{"type" => "string"},
          "visibility" => %{"type" => "string", "enum" => ["project", "private"]},
          "title" => %{"type" => "string"},
          "origin" => origin(),
          "request_id" => string(100)
        },
        ["project_id", "request_id"]
      ),
      tool(
        "send_prompt",
        "Queue a prompt durably on an existing thread; its runtime and model stay unchanged. Reuse request_id only to retry the same prompt; use wait_task for completion.",
        "tracks:write",
        %{
          "thread_id" => string(),
          "track_id" => string(),
          "prompt" => string(100_000),
          "request_id" => string(100)
        },
        ["track_id", "prompt", "request_id"]
      ),
      tool(
        "close_track",
        "Close a track as its creator or the project owner, exactly as Close in the browser does (a private track only by its creator). Irreversible: the track's machine or worktree is discarded, uncommitted and unpushed work with it, and its queued prompts are cancelled. Refuses a track with a running turn (track_running) or queued prompts (prompts_queued) unless force is true; force also discards uncommitted changes in a shared worktree. require_merged refuses unless the track's pull request is merged (pr_not_merged). Returns closed and pr {number, state}, state being merged, open, closed, none or unknown. Reuse request_id only to retry the same close.",
        "tracks:write",
        %{
          "track_id" => string(),
          "force" => %{"type" => "boolean"},
          "require_merged" => %{"type" => "boolean"},
          "request_id" => string(100)
        },
        ["track_id", "request_id"]
      ),
      tool(
        "get_task",
        "Read the state and reply of a task submitted by this client.",
        "tracks:read",
        %{"task_id" => string()},
        ["task_id"]
      ),
      tool(
        "wait_task",
        "Wait up to timeout_ms (default/max 50000) for any owned task to change. Returns tasks, changed task IDs, and stale (true if reconciliation of still-active work could not finish within the budget or another event arrived during refresh). timeout_ms: 0 performs one refresh with a 250 ms budget, without waiting for changes. Server-side turn and queue events persist task states; terminal and held states do not require a provider read. Without since, terminal, input-required and blocked tasks count as changed. Pass metadata.ravix.status_version in since to acknowledge both state and reason changes; state strings remain supported. Missing since entries also detect held tasks. Remove finished tasks or pass their states in since on the next call. One active wait per user/client; concurrent waits return rate_limited.",
        "tracks:read",
        %{
          "task_ids" => %{
            "type" => "array",
            "items" => string(),
            "minItems" => 1,
            "maxItems" => 50,
            "uniqueItems" => true
          },
          "since" => %{
            "type" => "object",
            "maxProperties" => 50,
            "additionalProperties" => string()
          },
          "timeout_ms" => %{"type" => "integer", "minimum" => 0, "maximum" => 50_000}
        },
        ["task_ids"]
      ),
      tool(
        "retry_setup",
        "Retry track setup using the same action as Retry setup in the browser. After setup succeeds, call retry_task to resend a failed saved prompt.",
        "tracks:write",
        %{"track_id" => string()},
        ["track_id"]
      ),
      tool(
        "retry_task",
        "Requeue a failed or unconfirmed prompt as its sender or project owner. Check the transcript first: an unconfirmed POST may have arrived. This explicitly resends the saved prompt.",
        "tracks:write",
        %{"task_id" => string()},
        ["task_id"]
      ),
      tool(
        "cancel_task",
        "Cancel a queued, failed or unconfirmed prompt as its sender or project owner. Sending and delivered prompts cannot be canceled.",
        "tracks:cancel",
        %{"task_id" => string()},
        ["task_id"]
      ),
      tool(
        "read_track",
        "Read a bounded page of track events. Pass next_cursor as after to continue. " <>
          "People's comments on the thread are not included: they are never agent context.",
        "tracks:read",
        %{
          "track_id" => string(),
          "thread_id" => string(),
          "after" => integer(),
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
        },
        ["track_id"]
      )
    ] ++ PlanCatalog.tools()
  end

  def find(name), do: Enum.find(tools(), &(&1.name == name))
  def public(tool), do: Map.drop(tool, [:scope])

  def validate(value, %{"type" => "object", "properties" => properties} = schema)
      when is_map(value) do
    Enum.all?(Map.get(schema, "required", []), &Map.has_key?(value, &1)) and
      Enum.all?(value, fn {k, v} -> Map.has_key?(properties, k) and validate(v, properties[k]) end)
  end

  def validate(value, %{"type" => "object", "additionalProperties" => item} = schema)
      when is_map(value) and is_map(item) do
    map_size(value) <= Map.get(schema, "maxProperties", 100) and
      Enum.all?(value, fn {key, value} -> is_binary(key) and validate(value, item) end)
  end

  def validate(value, %{"type" => "object"}) when is_map(value), do: true

  def validate(value, %{"type" => "string"} = schema) when is_binary(value),
    do:
      (not Map.has_key?(schema, "maxLength") or
         length(String.codepoints(value)) <= schema["maxLength"]) and
        length(String.codepoints(value)) >= Map.get(schema, "minLength", 0) and
        enum?(value, schema)

  def validate(value, %{"type" => "integer"} = schema) when is_integer(value),
    do:
      (not Map.has_key?(schema, "minimum") or value >= schema["minimum"]) and
        (not Map.has_key?(schema, "maximum") or value <= schema["maximum"])

  def validate(value, %{"type" => "boolean"}) when is_boolean(value), do: true

  def validate(value, %{"type" => "array", "items" => item} = schema) when is_list(value),
    do:
      length(value) >= Map.get(schema, "minItems", 0) and
        length(value) <= Map.get(schema, "maxItems", 100) and
        (not Map.get(schema, "uniqueItems", false) or length(Enum.uniq(value)) == length(value)) and
        Enum.all?(value, &validate(&1, item))

  def validate(_, _), do: false

  def scopes(%{name: "assign_items"}), do: ["plans:write", "tracks:write"]
  def scopes(tool), do: [tool.scope]
  def allowed?(tool, scopes), do: Enum.all?(scopes(tool), &(&1 in scopes))

  defp enum?(value, %{"enum" => values}), do: value in values
  defp enum?(_, _), do: true
  defp string(max \\ 200), do: %{"type" => "string", "minLength" => 1, "maxLength" => max}
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
        destructiveHint: scope in ["projects:write", "tracks:cancel"] or name == "close_track",
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
        "packages" => %{"type" => "object"},
        "env_vars" => %{
          "type" => "object",
          "maxProperties" => 100,
          "additionalProperties" => %{"type" => "string", "maxLength" => 16_384}
        }
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
