defmodule Ravix.Fountain.FakeTransport do
  @moduledoc """
  A scripted Fountain, standing in for `Fountain.HTTP.Finch`.

  A test builds a client from a list of `{request, response}` expectations;
  every call `Ravix.Fountain` makes through it is matched against the first
  remaining expectation that fits, consumed, and recorded. When the test
  exits, an expectation still unconsumed, or a request nothing expected,
  fails it.

      client =
        FakeTransport.client([
          {%{method: "GET", path: "/api/catalog"}, {200, [], %{data: %{runtimes: ["claude"]}}}}
        ])

      {:ok, catalog} = Ravix.Fountain.catalog(client)
      [%{headers: headers}] = FakeTransport.calls(client)

  A request matcher is a map: `:method` and `:path` (required), `:query`
  (a map, compared whole), `:body` (compared as decoded JSON), `:headers`
  (a list of pairs that must each be present). A response is
  `{status, headers, body}` where the body is JSON-encoded unless it is a
  binary. For streams the body is a list of chunks fed to the SDK in order
  (a binary is one chunk), or the error body when the status is not 2xx.
  `{:error, reason}` stands for a transport failure. A response may also be a
  function of the recorded call. `frame/3` builds an SSE frame.

  The SDK opens streams from a process of its own, so the script cannot live
  in the test process: it lives in one unlinked agent keyed by an id carried
  in the client's host, `http://fake-<id>.fountain.test`.
  """

  alias Ravix.Fountain.Client

  @scripts __MODULE__.Scripts

  @type matcher :: %{
          required(:method) => String.t(),
          required(:path) => String.t(),
          optional(:query) => map(),
          optional(:body) => term(),
          optional(:headers) => [{String.t(), String.t()}]
        }
  @type response ::
          {non_neg_integer(), [{String.t(), String.t()}], term()}
          | {:error, term()}
          | (call() -> term())
  @type call :: %{
          method: String.t(),
          path: String.t(),
          query: map(),
          headers: [{String.t(), String.t()}],
          body: term(),
          url: String.t()
        }

  # ── the test's side ───────────────────────────────────────────────────

  @doc """
  A client on this transport, scripted with `expectations`.

  Registers an `on_exit` that verifies the script unless `verify: false`.
  Other options go to `Ravix.Fountain.Client.new/3`.
  """
  @spec client([{matcher(), response()}], keyword()) :: Client.t()
  def client(expectations \\ [], opts \\ []) do
    ensure_started()
    id = System.unique_integer([:positive])

    Agent.update(@scripts, fn scripts ->
      Map.put(scripts, id, %{
        remaining: Enum.map(expectations, &normalize/1),
        calls: [],
        unmatched: []
      })
    end)

    client =
      Client.new(
        "http://fake-#{id}.fountain.test",
        Keyword.get(opts, :api_key, "fake-key"),
        Keyword.merge([transport: __MODULE__], Keyword.drop(opts, [:api_key, :verify]))
      )

    if Keyword.get(opts, :verify, true) do
      ExUnit.Callbacks.on_exit(fn ->
        try do
          verify!(client)
        after
          Agent.update(@scripts, &Map.delete(&1, id))
        end
      end)
    end

    client
  end

  @doc "Add an expectation to a live client's script."
  @spec expect(Client.t(), matcher(), response()) :: :ok
  def expect(client, matcher, response) do
    id = id_of(client)
    expectation = normalize({matcher, response})

    Agent.update(@scripts, fn scripts ->
      update_in(scripts, [id, :remaining], &(&1 ++ [expectation]))
    end)
  end

  @doc "Every request made through the client, oldest first."
  @spec calls(Client.t()) :: [call()]
  def calls(client) do
    Agent.get(@scripts, fn scripts -> Enum.reverse(get_in(scripts, [id_of(client), :calls])) end)
  end

  @doc "Raise unless every expectation was consumed and every request was expected."
  @spec verify!(Client.t()) :: :ok
  def verify!(client) do
    script = Agent.get(@scripts, &Map.get(&1, id_of(client)))

    cond do
      is_nil(script) ->
        :ok

      script.unmatched != [] ->
        raise "Fountain fake: unexpected request(s): " <>
                Enum.map_join(Enum.reverse(script.unmatched), ", ", &describe/1)

      script.remaining != [] ->
        raise "Fountain fake: expected request(s) never made: " <>
                Enum.map_join(script.remaining, ", ", fn {matcher, _} -> describe(matcher) end)

      true ->
        :ok
    end
  end

  @doc "One server-sent frame, as Fountain writes it: `id`, `event`, JSON `data`."
  @spec frame(integer() | nil, String.t(), map()) :: String.t()
  def frame(id, event, data) do
    id_line = if id, do: "id: #{id}\n", else: ""
    "#{id_line}event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
  end

  # ── the SDK's side (the shape of Fountain.HTTP.Finch) ─────────────────

  @doc false
  def request(method, url, headers, body, _timeout) do
    case take(method, url, headers, decode(body)) do
      {:ok, {status, response_headers, response_body}} ->
        {:ok, status, response_headers, encode(response_body)}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:unmatched, call} ->
        {:error, %RuntimeError{message: "unexpected Fountain request " <> describe(call)}}
    end
  end

  @doc false
  def stream(method, url, headers, _timeout, on_chunk) do
    case take(method, url, headers, nil) do
      {:ok, {status, response_headers, chunks}} when status in 200..299 ->
        chunks |> List.wrap() |> Enum.each(on_chunk)
        {:ok, status, response_headers, nil}

      {:ok, {status, response_headers, body}} ->
        {:ok, status, response_headers, encode(body)}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:unmatched, call} ->
        {:error, %RuntimeError{message: "unexpected Fountain request " <> describe(call)}}
    end
  end

  # ── matching ──────────────────────────────────────────────────────────

  defp take(method, url, headers, body) do
    uri = URI.parse(url)
    id = id_of_host(uri.host)

    call = %{
      method: String.upcase(to_string(method)),
      path: uri.path || "/",
      query: if(uri.query, do: URI.decode_query(uri.query), else: %{}),
      headers: Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end),
      body: body,
      url: url
    }

    Agent.get_and_update(@scripts, fn scripts ->
      case Map.fetch(scripts, id) do
        :error ->
          {{:unmatched, call}, scripts}

        {:ok, script} ->
          {result, script} = consume(%{script | calls: [call | script.calls]}, call)
          {result, Map.put(scripts, id, script)}
      end
    end)
  end

  # The first remaining expectation that fits, consumed; or the call filed as unmatched.
  defp consume(script, call) do
    case Enum.find_index(script.remaining, fn {matcher, _} -> matches?(matcher, call) end) do
      nil ->
        {{:unmatched, call}, %{script | unmatched: [call | script.unmatched]}}

      index ->
        {{_matcher, response}, remaining} = List.pop_at(script.remaining, index)
        response = if is_function(response, 1), do: response.(call), else: response
        {{:ok, response}, %{script | remaining: remaining}}
    end
  end

  defp matches?(matcher, call) do
    matcher.method == call.method and matcher.path == call.path and
      (not Map.has_key?(matcher, :query) or matcher.query == call.query) and
      (not Map.has_key?(matcher, :body) or matcher.body == call.body) and
      (not Map.has_key?(matcher, :headers) or Enum.all?(matcher.headers, &(&1 in call.headers)))
  end

  defp normalize({{method, path}, response}),
    do: normalize({%{method: method, path: path}, response})

  defp normalize({matcher, response}) when is_map(matcher) do
    matcher =
      matcher
      |> Map.update!(:method, &String.upcase/1)
      |> normalize_key(:body, &roundtrip/1)
      |> normalize_key(:headers, &lower_headers/1)
      |> normalize_key(:query, &Map.new(&1, fn {k, v} -> {to_string(k), to_string(v)} end))

    {matcher, response}
  end

  defp normalize_key(matcher, key, fun) do
    if Map.has_key?(matcher, key), do: Map.update!(matcher, key, fun), else: matcher
  end

  defp lower_headers(headers),
    do: Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

  defp roundtrip(nil), do: nil
  defp roundtrip(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp decode(nil), do: nil
  defp decode(""), do: nil

  defp decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, value} -> value
      _ -> raw
    end
  end

  defp encode(nil), do: ""
  defp encode(body) when is_binary(body), do: body
  defp encode(body), do: Jason.encode!(body)

  defp describe(%{method: method, path: path} = call) do
    query = Map.get(call, :query, %{})
    suffix = if query == %{}, do: "", else: "?" <> URI.encode_query(query)
    "#{method} #{path}#{suffix}"
  end

  defp id_of(%Client{base_url: base_url}),
    do: base_url |> URI.parse() |> Map.get(:host) |> id_of_host()

  defp id_of_host("fake-" <> rest) do
    rest |> String.split(".") |> hd() |> String.to_integer()
  end

  defp id_of_host(_host), do: nil

  defp ensure_started do
    case Agent.start(fn -> %{} end, name: @scripts) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
