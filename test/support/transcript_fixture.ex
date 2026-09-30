defmodule Ravix.TranscriptFixture do
  @moduledoc "ACP regression wire shapes and a synthetic long tool-heavy conversation."

  alias Ravix.Fountain.Shapes

  def update(shape),
    do: Jason.encode!(%{jsonrpc: "2.0", method: "session/update", params: %{update: shape}})

  def text(body),
    do: %{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: body}}

  def thought(body),
    do: %{sessionUpdate: "agent_thought_chunk", content: %{type: "text", text: body}}

  def call(id),
    do: %{sessionUpdate: "tool_call", toolCallId: id, title: "Read file", kind: "read"}

  def result(id),
    do: %{
      sessionUpdate: "tool_call_update",
      toolCallId: id,
      status: "completed",
      content: [%{type: "content", content: %{type: "text", text: "defmodule Example do\nend"}}]
    }

  def output(id, shape, turn \\ "t"),
    do: %{
      "id" => id,
      "turn_id" => turn,
      "kind" => "output",
      "stream" => "acp",
      "data" => update(shape)
    }

  def stage(id, state),
    do: %{"id" => id, "turn_id" => "t", "kind" => "stage", "stage" => "turn", "state" => state}

  def sample(count) do
    calls = div(count, 4)

    shapes =
      Enum.flat_map(1..calls, fn n ->
        [
          call("tool-#{n}"),
          thought("Inspecting module #{n}."),
          text("Checking the implementation.\n")
        ]
      end) ++ Enum.map(1..calls, &result("tool-#{&1}"))

    [stage(1, "started")] ++
      (shapes
       |> Enum.take(count - 2)
       |> Enum.with_index(2)
       |> Enum.map(fn {shape, id} -> output(id, shape) end)) ++
      [stage(count, "completed")]
  end

  def corpus do
    plan = %{sessionUpdate: "plan", entries: [%{content: "Inspect", status: "in_progress"}]}

    shapes = [
      text("Hel"),
      text("lo"),
      thought("Think"),
      thought("ing"),
      call("a"),
      call("b"),
      plan,
      text("between"),
      result("a"),
      %{plan | entries: []},
      text("after clearing"),
      result("b"),
      call("a"),
      result("a"),
      result("orphan"),
      %{plan | entries: [%{content: "Done", status: "completed"}]}
    ]

    tools =
      ([stage(1, "started")] ++ Enum.with_index(shapes, 2))
      |> Enum.map(fn
        {shape, id} -> output(id, shape)
        event -> event
      end)

    %{
      "tools-plans-text" => tools ++ [stage(30, "completed")],
      "codex-outage" => Ravix.AgentOutageFixture.events(),
      "duplicates-out-of-order" => [
        output(3, text("third")),
        output(1, text("first")),
        output(2, text("second")),
        output(2, text("ignored"))
      ],
      "interleaved-turns" => [
        output(1, call("same"), "a"),
        output(2, call("same"), "b"),
        output(3, result("same"), "a"),
        output(4, result("same"), "b")
      ],
      "legacy-and-raw" => [
        %{
          "id" => 1,
          "turn_id" => "t",
          "kind" => "output",
          "stream" => "stdout",
          "data" => "legacy"
        },
        %{
          "id" => 2,
          "turn_id" => "t",
          "kind" => "output",
          "stream" => "acp",
          "data" => "not JSON\n"
        },
        Map.put(stage(3, "failed"), "data", "")
      ]
    }
  end

  def public(%_{} = struct),
    do:
      struct
      |> Map.from_struct()
      |> Map.drop([
        :fold,
        :failure,
        :config_selection,
        :conversation_id,
        :history,
        :oldest_event_id,
        :oldest_conversation_id
      ])
      |> public()

  def public(map) when is_map(map),
    do:
      Map.new(map, fn {key, value} ->
        {key, public(payload(key, value))}
      end)

  def public(list) when is_list(list), do: Enum.map(list, &public/1)
  def public(value), do: value

  defp payload(key, value) when key in [:data, :details] and is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp payload(_key, value), do: value

  # ── Fountain's events feed (managoat/fountain#2531) ─────────────────────

  @doc """
  `GET /api/conversations/:id/events` over `log` (ascending, string keys),
  as a `FakeTransport` response: forward pages after `after`, or with
  `order=desc` the newest page below `before`, extended by `whole_turns=true`
  to every page turn's first event up to `:max` events (Fountain's 5,000),
  the way `Conversations._unsafe_list_log_events_backward/2` builds it.
  `legacy: true` is a Fountain older than #2531: no `page` object, and
  `order`, `before` and `whole_turns` are ignored.
  """
  def events_response(log, opts \\ []),
    do: fn call -> {200, [], events_body(log, call.query, opts)} end

  @doc "The JSON body `events_response/2` answers for a string-keyed `query`."
  def events_body(log, query, opts \\ []) do
    legacy? = Keyword.get(opts, :legacy, false)
    # An older Fountain reads neither `order` nor `before`.
    query = if legacy?, do: Map.drop(query, ["order", "before"]), else: query
    desc? = query["order"] == "desc"
    {page, more?, split?} = select(log, query, Keyword.get(opts, :max, 5000))
    ids = Enum.map(page, & &1["id"])

    body = %{
      "data" => page,
      "meta" => %{"limit" => limit(query), "has_more" => more?, "next_cursor" => List.last(ids)}
    }

    if legacy?,
      do: body,
      else:
        Map.put(body, "page", %{
          "order" => if(desc?, do: "desc", else: "asc"),
          "oldest_cursor" => Enum.min(ids, fn -> nil end),
          "newest_cursor" => Enum.max(ids, fn -> nil end),
          "turn_split" => split?
        })
  end

  defp select(log, query, max) do
    after_id = String.to_integer(query["after"] || "0")
    before = if query["before"], do: String.to_integer(query["before"])
    rows = Enum.filter(log, &(&1["id"] > after_id and (is_nil(before) or &1["id"] < before)))
    limit = limit(query)

    if query["order"] == "desc",
      do: backward(rows, limit, query["whole_turns"] == "true", max),
      else: {Enum.take(rows, limit), length(rows) > limit, false}
  end

  defp limit(query), do: String.to_integer(query["limit"] || "100")

  @doc """
  The chain of newest-first requests a reader makes over `log`, each with
  the `before` the previous page handed back: `[{query, body}]`. `:limit`
  is the first page's (a read's, 200) and `:then` every later one's, which
  is 1,000 for the classification scan continuing from a read.
  """
  def desc_pages(log, opts \\ []) do
    first = Keyword.get(opts, :limit, 200)

    base = %{
      "order" => "desc",
      "whole_turns" => "true",
      "limit" => to_string(first),
      "blocks" => "true",
      "prompts" => "true"
    }

    later = Map.put(base, "limit", to_string(Keyword.get(opts, :then, first)))

    Stream.unfold(base, fn
      nil ->
        nil

      query ->
        body = events_body(log, query, opts)
        more? = body["meta"]["has_more"]
        next = if more?, do: Map.put(later, "before", to_string(body["meta"]["next_cursor"]))
        {{query, body}, next}
    end)
    |> Enum.to_list()
  end

  @doc "`FakeTransport` expectations for `desc_pages/2` at `path`, in order."
  def desc_routes(path, log, opts \\ []) do
    for {query, body} <- desc_pages(log, opts),
        do: {%{method: "GET", path: path, query: query}, {200, [], body}}
  end

  @doc "What `Ravix.Fountain.events_page/3` answers for `opts` over `log`, for a Mimic stub."
  def events_page(log, opts) do
    query =
      for {key, value} <- [
            limit: opts[:limit] || 1000,
            before: opts[:before],
            order: opts[:order],
            whole_turns: opts[:whole_turns]
          ],
          value not in [nil, false],
          into: %{},
          do: {to_string(key), to_string(value)}

    body = events_body(log, query)

    {:ok,
     %{
       events: body["data"],
       has_more: body["meta"]["has_more"],
       next_cursor: body["meta"]["next_cursor"],
       window: Shapes.event_window(body["page"])
     }}
  end

  defp backward(rows, limit, whole?, max) do
    desc = Enum.reverse(rows)

    case Enum.split(desc, limit) do
      {page, []} -> {page, false, false}
      {page, _older} when not whole? -> {page, true, false}
      {page, _older} -> complete(rows, desc, page, List.last(page)["id"], max, turn_ids(page))
    end
  end

  defp complete(rows, desc, page, floor, max, new_turns) do
    start =
      new_turns
      |> Enum.map(fn turn -> Enum.find(rows, &(&1["turn_id"] == turn))["id"] end)
      |> Enum.min(fn -> nil end)

    if start && start < floor do
      room = max - length(page)
      extra = Enum.filter(desc, &(&1["id"] >= start and &1["id"] < floor))

      if length(extra) > room,
        do: {page ++ Enum.take(extra, room), true, true},
        else: complete(rows, desc, page ++ extra, start, max, turn_ids(extra))
    else
      {page, Enum.any?(desc, &(&1["id"] < floor)), false}
    end
  end

  defp turn_ids(events),
    do: for(%{"turn_id" => turn} <- events, turn != nil, uniq: true, do: turn)
end
