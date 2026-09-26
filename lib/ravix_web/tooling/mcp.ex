defmodule RavixWeb.Tooling.MCP do
  @moduledoc "MCP tools over stateless Streamable HTTP. Work outlives the HTTP call."
  alias Ravix.Tooling
  alias Ravix.Tooling.Catalog
  alias RavixWeb.Error

  def call(principal, request) do
    case request do
      %{"method" => "notifications/" <> _} ->
        :notification

      %{"id" => id} when not is_nil(id) ->
        method(principal, request["method"], Map.get(request, "params", %{}))

      _ ->
        {:error, -32_600, "A request ID is required"}
    end
  end

  defp method(_, "initialize", params) do
    version =
      if params["protocolVersion"] in ["2025-03-26", "2025-06-18", "2025-11-25"],
        do: params["protocolVersion"],
        else: "2025-11-25"

    {:ok,
     %{
       protocolVersion: version,
       capabilities: %{tools: %{listChanged: false}},
       serverInfo: %{name: "ravix", version: "1.0.0"},
       instructions:
         "Use request_id for mutations. Assign with send_prompt, then loop wait_task with task_ids and the last states in since. Delivery is not completion."
     }}
  end

  defp method(_, "ping", _), do: {:ok, %{}}

  defp method(p, "tools/list", _) do
    {:ok,
     %{
       tools:
         Catalog.tools()
         |> Enum.filter(&Catalog.allowed?(&1, p.grant.scopes))
         |> Enum.map(&Catalog.public/1)
     }}
  end

  defp method(p, "tools/call", %{"name" => name} = params) when is_binary(name) do
    case Tooling.call(p, name, Map.get(params, "arguments", %{})) do
      {:ok, result} ->
        object = if is_map(result), do: result, else: %{items: result}

        {:ok,
         %{
           content: [%{type: "text", text: Jason.encode!(object)}],
           structuredContent: object,
           isError: false
         }}

      {:error, {:unprocessable, "unknown_tool", message}} ->
        {:error, -32_602, message}

      {:error, reason} ->
        error = Error.from(reason)
        details = error_details(error, name, Map.get(params, "arguments", %{}))

        {:ok,
         %{
           content: [%{type: "text", text: Jason.encode!(details)}],
           structuredContent: %{error: details},
           isError: true
         }}
    end
  end

  defp method(_, "tools/call", _), do: {:error, -32_602, "A tool name is required"}
  defp method(_, _, _), do: {:error, -32_601, "Method not found"}

  defp error_details(error, name, args) do
    details = %{code: error.code, message: error.message}

    if name == "create_track" and error.code in ["invalid_branch", "branch_taken"] do
      field = if Map.has_key?(args, "branch_name"), do: "branch_name", else: "title"
      Map.put(details, :field, field)
    else
      details
    end
  end
end
