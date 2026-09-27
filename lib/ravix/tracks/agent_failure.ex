defmodule Ravix.Tracks.AgentFailure do
  @moduledoc "Bounded classification of terminal agent transport failures, never arbitrary reply text."
  alias Ravix.Tracks.Transcript.{Block, Event}

  @code "agent_provider_unreachable"
  @transport ~w(responseStreamDisconnected responseStreamConnectionFailed)

  def code, do: @code

  @doc "Classify one settled turn. Retry notifications alone are not terminal failures."
  def detect(events, runtime, blocks) do
    frames = Enum.flat_map(events, &frames/1)

    if outage?(frames) or timeout_reply?(blocks) do
      %{code: @code, reason: message(runtime, frames, blocks)}
    end
  end

  defp outage?(frames) do
    terminal? = Enum.any?(frames, &system_error?/1)
    transport? = Enum.any?(frames, &transport?/1)
    approval? = Enum.any?(frames, &approval_failure?/1)
    (terminal? and transport?) or approval?
  end

  defp system_error?(frame) do
    any_node?(frame, fn node ->
      Enum.any?(
        ~w(stopReason stop_reason status type sessionUpdate),
        &(node[&1] == "systemError")
      )
    end)
  end

  defp transport?(frame) do
    any_node?(frame, fn node ->
      info = node["codexErrorInfo"]

      (is_map(info) and Enum.any?(@transport, &Map.has_key?(info, &1))) or
        info in @transport or transport_text?(node["message"])
    end)
  end

  # Only an explicitly failed review's structured error counts. A normal
  # request_permission or an agent asking to approve a fetch is not an outage.
  defp approval_failure?(frame) do
    any_node?(frame, fn node ->
      review = node["approvalReview"]
      is_map(review) and review["status"] == "failed" and transport?(review["error"])
    end)
  end

  defp transport_text?(text) when is_binary(text),
    do:
      String.contains?(text, [
        "stream disconnected before completion",
        "Transport error: timeout",
        "error decoding response body"
      ])

  defp transport_text?(_), do: false

  defp timeout_reply?([%Block.Text{body: body}]), do: String.trim(body) == "request timed out"
  defp timeout_reply?(_), do: false

  defp message(runtime, frames, blocks) do
    agent = Ravix.AgentName.label(runtime) || "The agent"

    provider =
      case runtime do
        "codex" -> "OpenAI"
        runtime when runtime in ["claude", "claude-code"] -> "Anthropic"
        _ -> "its model provider"
      end

    attempts =
      frames |> Enum.map(&retry_count/1) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)

    detail = if attempts, do: " (the connection failed after #{attempts} retries)", else: ""

    changes =
      if Enum.any?(blocks, &match?(%Block.Tool{}, &1)), do: "", else: " Nothing was changed."

    "#{agent} couldn't reach #{provider}#{detail}.#{changes} Retry."
  end

  defp retry_count(frame) do
    nodes(frame)
    |> Enum.find_value(fn node ->
      case node["retryCount"] || node["retryAttempt"] do
        n when is_integer(n) and n in 1..100 -> n
        _ -> nil
      end
    end)
  end

  @doc "A GitHub auth rejection in a tool result, with expiry evidence, gets a safe notice."
  def github_notice(events, blocks) do
    if Enum.any?(blocks, &github_expired?(&1, true)) and
         Enum.any?(blocks, &github_expired?(&1, elapsed?(events))),
       do: "GitHub access for this turn expired — send another message to refresh it."
  end

  defp github_expired?(%Block.Tool{output: output, name: name, summary: summary}, expired?) do
    source = Enum.join([name || "", summary || "", output], " ")
    github? = String.contains?(source, ["github.com", "api.github.com", "gh ", "GitHub"])
    rejected? = String.contains?(output, ["401", "Invalid username or token", "Bad credentials"])
    github? and rejected? and (expired? or String.contains?(output, "expired"))
  end

  defp github_expired?(_, _), do: false

  defp elapsed?(events) do
    times = Enum.flat_map(events, &event_time/1)

    times != [] and Enum.max(times) - Enum.min(times) >= 3600
  end

  defp event_time(event) do
    case Event.from(event).ts do
      ts when is_binary(ts) -> parse_time(ts)
      _ -> []
    end
  end

  defp parse_time(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, time, _} -> [DateTime.to_unix(time)]
      _ -> []
    end
  end

  defp frames(raw) do
    case Event.from(raw) do
      %Event{kind: kind, stream: stream, data: data}
      when is_binary(data) and (kind == :stage or stream == :acp) ->
        data
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_frame/1)

      _ ->
        []
    end
  end

  defp decode_frame(line) do
    case Jason.decode(line) do
      {:ok, frame} when is_map(frame) -> [frame]
      _ -> []
    end
  end

  defp any_node?(value, predicate), do: Enum.any?(nodes(value), predicate)
  # Tool arguments/results and quoted message content are data, not protocol
  # signals. A repository fixture containing systemError must stay ordinary output.
  defp nodes(map) when is_map(map) do
    children = Map.drop(map, ~w(rawInput rawOutput content prompt blocks))
    [map | Enum.flat_map(Map.values(children), &nodes/1)]
  end

  defp nodes(list) when is_list(list), do: Enum.flat_map(list, &nodes/1)
  defp nodes(_), do: []
end
