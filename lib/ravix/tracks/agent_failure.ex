defmodule Ravix.Tracks.AgentFailure do
  @moduledoc "Bounded classification of terminal agent transport failures, never arbitrary reply text."
  alias Ravix.Tracks.Transcript.{Block, Event}

  @code "agent_provider_unreachable"
  @transport ~w(responseStreamDisconnected responseStreamConnectionFailed)

  def code, do: @code

  @doc "Classify one settled turn. Retry notifications alone are not terminal failures."
  def detect(events, runtime, blocks) do
    frames = Enum.flat_map(events, &frames/1)

    suspension(events) ||
      if outage?(frames) or timeout_reply?(blocks) do
        %{code: @code, reason: message(runtime, frames, blocks)}
      end
  end

  @doc "Fixed-size evidence for incremental task receipts; no raw frames are retained."
  def accumulate(summary, events, blocks) do
    frames = Enum.flat_map(events, &frames/1)
    closed = summary["closed"] == true
    suspension = if closed, do: nil, else: suspension(events)

    suspension =
      if suspension, do: %{suspension | reason: String.slice(suspension.reason, 0, 512)}

    text =
      Enum.map_join(blocks, fn
        %Block.Text{body: body} -> body
        _ -> ""
      end)

    summary
    |> accumulate_signals(frames, blocks)
    |> Map.put("timeout", timeout_progress(Map.get(summary, "timeout", ""), text))
    |> Map.put(
      "retries",
      max(
        summary["retries"] || 0,
        Enum.max(Enum.map(frames, &(retry_count(&1) || 0)), fn -> 0 end)
      )
    )
    |> Map.put(
      "closed",
      closed or
        Enum.any?(events, &(Event.from(&1).stage == "turn" and Event.settles?(Event.from(&1))))
    )
    |> Map.put("suspension", summary["suspension"] || suspension)
  end

  defp accumulate_signals(summary, frames, blocks) do
    signals = %{
      "system" => Enum.any?(frames, &system_error?/1),
      "transport" => Enum.any?(frames, &transport?/1),
      "approval" => Enum.any?(frames, &approval_failure?/1),
      "tool" => Enum.any?(blocks, &match?(%Block.Tool{}, &1)),
      "other" => Enum.any?(blocks, &(not match?(%Block.Text{}, &1)))
    }

    Map.merge(summary, signals, fn _key, old, new -> old == true or new end)
  end

  # The only text-dependent classifier recognizes one fixed phrase. Keeping its
  # prefix (and trailing whitespace state) bounds evidence independently of reply length.
  defp timeout_progress(false, _), do: false

  defp timeout_progress(prefix, text) do
    combined = prefix <> text
    trimmed = String.trim(combined)

    cond do
      trimmed == "request timed out" ->
        "request timed out" <> if(String.trim_trailing(combined) == combined, do: "", else: " ")

      String.starts_with?("request timed out", String.trim_leading(combined)) ->
        String.trim_leading(combined)

      true ->
        false
    end
  end

  @doc "Apply the same failure classification after the last page, using bounded evidence."
  def from_summary(summary, runtime, finished) do
    suspension = summary["suspension"]

    cond do
      is_map(suspension) ->
        %{
          code: suspension["code"] || suspension[:code],
          reason: suspension["reason"] || suspension[:reason]
        }

      finished and summary_outage?(summary) ->
        frames = [%{"retryCount" => summary["retries"]}]
        blocks = if summary["tool"], do: [struct(Block.Tool)], else: []
        %{code: @code, reason: message(runtime, frames, blocks)}

      true ->
        nil
    end
  end

  defp summary_outage?(summary) do
    (summary["system"] == true and summary["transport"] == true) or
      summary["approval"] == true or summary_timeout?(summary)
  end

  defp summary_timeout?(%{"timeout" => text} = summary) when is_binary(text),
    do: summary["other"] != true and String.trim(text) == "request timed out"

  defp summary_timeout?(_summary), do: false

  @doc "Suspension closes a turn even while the provider's turn status is catching up."
  def suspension(events) do
    events = Enum.map(events, &Event.from/1)

    case Enum.find(events, &(not is_nil(Event.suspension(&1)))) do
      nil -> nil
      event -> suspension_failure(event, events)
    end
  end

  defp suspension_failure(event, events) do
    # A machine also sleeps between turns. Do not rewrite a reply which had
    # already ended before this sandbox-wide notice arrived.
    closed = Enum.any?(events, &(&1.stage == "turn" and Event.settles?(&1) and &1.id < event.id))

    unless closed do
      %{
        code: "machine_suspended",
        reason:
          "The machine went to sleep during this turn#{idle_detail(Event.suspension(event))}. Send another message to continue."
      }
    end
  end

  defp idle_detail(%{"reason" => "idle", "message" => message}) when is_binary(message) do
    case Regex.run(~r/after (\d+) minutes idle/, message) do
      [_, minutes] -> " (idle for #{minutes} minutes)"
      _ -> ""
    end
  end

  defp idle_detail(_), do: ""

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
