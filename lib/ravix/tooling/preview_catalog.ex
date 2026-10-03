defmodule Ravix.Tooling.PreviewCatalog do
  @moduledoc "Preview and run tools, using existing track and project scopes."

  def names, do: Enum.map(tools(), & &1.name)

  def tools do
    [
      tool(
        "get_preview_config",
        "Read the effective run configuration and track override.",
        "tracks:read",
        track(),
        ["track_id"]
      ),
      tool(
        "preview_status",
        "Read preview/run state. Starts no service and issues no browser ticket.",
        "tracks:read",
        track(),
        ["track_id"]
      ),
      tool(
        "preview_logs",
        "Refresh the log tail without waking an idle machine. limit caps characters (default/max 4000).",
        "tracks:read",
        Map.put(track(), "limit", %{"type" => "integer", "minimum" => 1, "maximum" => 4000}),
        ["track_id"]
      ),
      tool(
        "update_preview_config",
        "Replace the track run override and stop its service. Supply config OR reset: true to inherit project defaults. Commands execute code. Reuse request_id only for identical work.",
        "tracks:write",
        configuration(track()),
        ["track_id", "request_id"]
      ),
      tool(
        "get_preview_defaults",
        "Read run defaults of a project you own.",
        "projects:write",
        project(),
        ["project_id"]
      ),
      tool(
        "update_preview_defaults",
        "Replace owned project run defaults and stop inheriting services. Supply config OR reset: true to clear. Commands execute code. Reuse request_id only for identical work.",
        "projects:write",
        configuration(project()),
        ["project_id", "request_id"]
      )
    ] ++
      Enum.map(~w(run_preview start_preview restart_preview stop_preview), fn name ->
        tool(
          name,
          action_description(name),
          "tracks:write",
          Map.put(track(), "request_id", string(100)),
          ["track_id", "request_id"]
        )
      end)
  end

  defp action_description("stop_preview"),
    do: "Stop the managed service. Reuse request_id only for identical work."

  defp action_description("restart_preview"),
    do:
      "Stop and restart the run/preview asynchronously. Poll preview_status for its outcome. Issues no browser ticket. Reuse request_id only for identical work."

  defp action_description(_),
    do:
      "Start the run/preview asynchronously, joining an existing start. Poll preview_status for its outcome. Issues no browser ticket. run_preview and start_preview are aliases; retry with the same tool name and request_id."

  defp configuration(properties) do
    Map.merge(properties, %{
      "request_id" => string(100),
      "reset" => %{"type" => "boolean"},
      "config" => %{
        "type" => "object",
        "properties" => %{
          "directory" => text(1000),
          "command" => string(8000),
          "stop_command" => text(8000),
          "readiness_path" => text(1000)
        },
        "required" => ["directory", "command"],
        "additionalProperties" => false
      }
    })
  end

  defp track, do: %{"track_id" => string()}
  defp project, do: %{"project_id" => string()}
  defp text(max), do: %{"type" => "string", "maxLength" => max}
  defp string(max \\ 200), do: Map.put(text(max), "minLength", 1)

  defp tool(name, description, scope, properties, required) do
    %{
      name: name,
      description: description,
      scope: scope,
      inputSchema: %{
        "type" => "object",
        "properties" => properties,
        "required" => required,
        "additionalProperties" => false
      }
    }
  end
end
