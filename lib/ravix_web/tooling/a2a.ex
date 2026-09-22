defmodule RavixWeb.Tooling.A2A do
  @moduledoc "A2A 1.0 JSON-RPC delegation. Context IDs are Ravix track IDs."
  alias Ravix.Tooling
  alias Ravix.Tooling.{OAuth, Tasks}
  alias RavixWeb.Error

  def extension, do: "https://ravix.sh/a2a/extensions/tracks/v1"

  def card do
    base = Ravix.Config.public_url()

    %{
      name: "Ravix",
      description: "Delegate coding work to persistent Ravix tracks.",
      version: "1.0.0",
      supportedInterfaces: [
        %{url: base <> "/a2a", protocolBinding: "JSONRPC", protocolVersion: "1.0"}
      ],
      capabilities: %{
        streaming: true,
        extensions: [
          %{
            uri: extension(),
            required: false,
            description:
              "contextId selects an existing track. metadata.ravix.projectId opens a new track; messageId deduplicates submission."
          }
        ]
      },
      securitySchemes: %{
        ravix: %{
          oauth2SecurityScheme: %{
            flows: %{
              authorizationCode: %{
                authorizationUrl: base <> "/oauth/authorize",
                tokenUrl: base <> "/oauth/token",
                scopes: Map.new(OAuth.scopes(), &{&1, &1})
              }
            }
          }
        }
      },
      securityRequirements: [%{schemes: %{ravix: %{list: ["tracks:read", "tracks:write"]}}}],
      defaultInputModes: ["text/plain"],
      defaultOutputModes: ["text/plain"],
      skills: [
        %{
          id: "coding-track",
          name: "Work on a track",
          tags: ["coding"],
          description:
            "Submit coding work, retrieve its reply and cancel queued work. Running tasks cannot be canceled."
        }
      ]
    }
  end

  def call(p, %{"id" => id} = request) when not is_nil(id) do
    method(p, request["method"], Map.get(request, "params", %{}))
  end

  def call(_, _), do: {:error, -32_600, "A request ID is required"}

  defp method(p, method, params) when method in ["SendMessage", "SendStreamingMessage"] do
    with {:ok, message, text} <- message(params),
         :ok <- configuration(params),
         {:ok, track_id} <- track(p, message, params),
         {:ok, task} <- Tasks.send(p, track_id, text, message["messageId"]) do
      cond do
        method == "SendStreamingMessage" ->
          {:stream, task}

        get_in(params, ["configuration", "returnImmediately"]) == true ->
          {:ok, %{task: Tasks.present(task)}}

        true ->
          {:wait, task}
      end
    else
      error -> error_result(error)
    end
  end

  defp method(p, "GetTask", %{"id" => id}) when is_binary(id), do: task_result(Tasks.get(p, id))

  defp method(p, "CancelTask", %{"id" => id}) when is_binary(id),
    do: task_result(Tasks.cancel(p, id))

  defp method(p, "SubscribeToTask", %{"id" => id}) when is_binary(id) do
    case Tasks.get(p, id) do
      {:ok, task} ->
        if Tasks.terminal?(task),
          do: {:error, -32_004, "Task already ended; use GetTask"},
          else: {:stream, task}

      error ->
        error_result(error)
    end
  end

  defp method(p, "ListTasks", params), do: list(p, params)

  defp method(_, method, _) when method in ["GetTask", "CancelTask", "SubscribeToTask"],
    do: {:error, -32_602, "A task ID is required"}

  defp method(_, method, _)
       when method in [
              "CreateTaskPushNotificationConfig",
              "GetTaskPushNotificationConfig",
              "ListTaskPushNotificationConfigs",
              "DeleteTaskPushNotificationConfig"
            ],
       do: {:error, -32_003, "Push notifications are not supported"}

  defp method(_, "GetExtendedAgentCard", _),
    do: {:error, -32_004, "Extended card is not supported"}

  defp method(_, _, _), do: {:error, -32_601, "Method not found"}

  defp message(%{
         "message" => %{"messageId" => id, "role" => "ROLE_USER", "parts" => parts} = message
       })
       when is_binary(id) and byte_size(id) in 1..100 and is_list(parts) and
              length(parts) in 1..20 do
    cond do
      message["taskId"] != nil ->
        {:error, -32_004,
         "Submit a new message in the same context; existing tasks do not accept follow-ups"}

      not Enum.all?(parts, &text_part?/1) ->
        {:error, -32_005, "Only text parts are supported"}

      true ->
        text = Enum.map_join(parts, "\n", & &1["text"])

        if byte_size(text) in 1..100_000,
          do: {:ok, message, text},
          else: {:error, -32_602, "Prompt is too large or empty"}
    end
  end

  defp message(_),
    do: {:error, -32_602, "A user message with messageId and text parts is required"}

  defp text_part?(%{"text" => text} = part),
    do: is_binary(text) and not Map.has_key?(part, "file") and not Map.has_key?(part, "data")

  defp text_part?(_), do: false

  defp configuration(params) do
    config = Map.get(params, "configuration", %{})

    cond do
      not is_map(config) ->
        {:error, -32_602, "Invalid configuration"}

      config["taskPushNotificationConfig"] != nil ->
        {:error, -32_003, "Push notifications are not supported"}

      config["returnImmediately"] not in [nil, true, false] ->
        {:error, -32_602, "returnImmediately must be boolean"}

      true ->
        :ok
    end
  end

  defp track(_p, %{"contextId" => id}, _params) when is_binary(id) and byte_size(id) > 0,
    do: {:ok, id}

  defp track(_p, %{"contextId" => _}, _params), do: {:error, -32_602, "Invalid contextId"}

  defp track(p, message, params) do
    case routing_project(params) do
      project when is_binary(project) ->
        case Tooling.call(p, "create_track", %{
               "project_id" => project,
               "request_id" => Tasks.digest({:track, message["messageId"]})
             }) do
          {:ok, track} -> {:ok, track[:id] || track["id"]}
          error -> error
        end

      _ ->
        {:error, -32_602, "Provide contextId or metadata.ravix.projectId"}
    end
  end

  defp routing_project(%{"metadata" => %{"ravix" => %{"projectId" => project}}}), do: project
  defp routing_project(_), do: nil

  defp list(p, params) do
    case Tasks.list(p, params) do
      {:ok, result} -> {:ok, result}
      error -> error_result(error)
    end
  end

  defp task_result({:ok, task}), do: {:ok, Tasks.present(task)}
  defp task_result(error), do: error_result(error)
  def error_result({:error, code, message}), do: {:error, code, message}
  def error_result({:error, :not_found}), do: {:error, -32_001, "Task or context not found"}

  def error_result({:error, {:conflict, "task_not_cancelable", message}}),
    do: {:error, -32_002, message}

  def error_result({:error, reason}) do
    error = Error.from(reason)
    {:error, -32_000, error.message}
  end
end
