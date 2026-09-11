defmodule Ravix.Fountain do
  @moduledoc """
  Fountain, on this server's key.

  Every other app in this suite hands the browser a Fountain key of its own
  (dns-desk, arena) or holds one key per signed-in person (paddock, salon).
  Ravix holds exactly one, for everybody, because sign-in is GitHub and a
  person here has no Fountain account to spend. That makes this module the
  whole of the app's access to Fountain: there is no proxy through which a
  browser can reach a path this module does not name.

  So it is typed rather than forwarding. Every function takes the client
  first (`client/0` builds it from `Ravix.Config.fountain/0`; tests build one
  on the fake transport) and answers `{:ok, value}`, `:ok`, or
  `{:error, %Ravix.Fountain.Error{}}`. A deployment with no key answers
  `{:error, :unconfigured}` from every call and never crashes.

  Over `fountain_sdk`: `Fountain.HTTP` carries the bearer header, the JSON
  encoding and the error structs; `Fountain.Conversation` the per-conversation
  reads and signals; `Fountain.SSE` the live transcript with its reconnect.
  The resource modules (`Fountain.Agents`, `Fountain.Environments`, ...) are
  not used: they resolve names through a per-process ETS cache, and Ravix only
  ever addresses records by id, from whichever process is handling a request.

  Failures are logged with the path and the status and nothing else: the body
  may be a secret value on its way to `/secrets`.
  """

  require Logger

  alias Fountain.HTTP
  alias Ravix.Fountain.{Client, Error, Shapes}

  @type id :: String.t()
  @type store :: :environments | :vaults
  @type record :: %{optional(String.t()) => term()}
  @type failure :: Error.t() | :unconfigured
  @type result(value) :: {:ok, value} | {:error, failure()}
  @type outcome :: :ok | {:error, failure()}
  @type events_page :: %{events: [record()], next_cursor: integer() | nil, has_more: boolean()}

  @page_limit 1000

  @doc "The client for this deployment, from `Ravix.Config.fountain/0`. Read at call time."
  @spec client() :: Client.t()
  def client do
    %{url: url, key: key} = Ravix.Config.fountain()
    Client.new(url, key)
  end

  # ── what this Fountain can do ─────────────────────────────────────────

  @doc """
  `GET /api/catalog`: the runtimes and models this Fountain runs.

  A `Ravix.Fountain.Shapes.Catalog`, not the record. It also serves
  `package_managers` and `mcp_servers`, which nothing here reads; see the
  shape for why they are not carried.
  """
  @spec catalog(Client.t()) :: result(Shapes.Catalog.t())
  def catalog(client) do
    with {:ok, raw} <- data(client, "GET", "/api/catalog"), do: {:ok, Shapes.catalog(raw)}
  end

  @doc "`GET /api/auth/me`: the account the key belongs to."
  @spec me(Client.t()) :: result(record())
  def me(client), do: data(client, "GET", "/api/auth/me")

  # ── the three records a project is ────────────────────────────────────

  @doc """
  `POST /api/environments`.

  `packages` is keyed by package manager, never a flat list: Fountain rejects
  an array outright (`{"packages":["Invalid object. Got: array"]}`).
  """
  @spec create_environment(Client.t(), map()) :: result(record())
  def create_environment(client, body), do: data(client, "POST", "/api/environments", body: body)

  @doc "`GET /api/environments/:id`."
  @spec get_environment(Client.t(), id()) :: result(record())
  def get_environment(client, id), do: data(client, "GET", "/api/environments/#{escape(id)}")

  @doc "`PUT /api/environments/:id`: a partial update, in place. The record is never replaced."
  @spec update_environment(Client.t(), id(), map()) :: result(record())
  def update_environment(client, id, body),
    do: data(client, "PUT", "/api/environments/#{escape(id)}", body: body)

  @doc "`DELETE /api/environments/:id`."
  @spec delete_environment(Client.t(), id()) :: outcome()
  def delete_environment(client, id),
    do: void(client, "DELETE", "/api/environments/#{escape(id)}")

  @doc "`POST /api/vaults`."
  @spec create_vault(Client.t(), map()) :: result(record())
  def create_vault(client, body), do: data(client, "POST", "/api/vaults", body: body)

  @doc "`DELETE /api/vaults/:id`."
  @spec delete_vault(Client.t(), id()) :: outcome()
  def delete_vault(client, id), do: void(client, "DELETE", "/api/vaults/#{escape(id)}")

  @doc "`POST /api/agents`. `model` is provider-prefixed (`anthropic/...`), because Fountain's are."
  @spec create_agent(Client.t(), map()) :: result(record())
  def create_agent(client, body), do: data(client, "POST", "/api/agents", body: body)

  @doc "`GET /api/agents/:id`."
  @spec get_agent(Client.t(), id()) :: result(record())
  def get_agent(client, id), do: data(client, "GET", "/api/agents/#{escape(id)}")

  @doc "`PUT /api/agents/:id`: a partial update, in place."
  @spec update_agent(Client.t(), id(), map()) :: result(record())
  def update_agent(client, id, body),
    do: data(client, "PUT", "/api/agents/#{escape(id)}", body: body)

  @doc "`DELETE /api/agents/:id`. Retiring the agent is what changes a project's identity."
  @spec delete_agent(Client.t(), id()) :: outcome()
  def delete_agent(client, id), do: void(client, "DELETE", "/api/agents/#{escape(id)}")

  # ── secrets ───────────────────────────────────────────────────────────

  @doc """
  Write one secret.

  The only call in this module whose body must never be logged, which is why
  failures log the path and the status and nothing else. `store` picks which
  of the two places it goes: the environment puts it in the box as an ordinary
  env var, the vault keeps it off the box entirely and lets Fountain's egress
  broker substitute it in flight. Ravix's clone token goes in the vault for
  exactly that reason.

  `POST /secrets` with both fields, not `PUT /secrets/:key`. Fountain's secret
  request requires `key` and `value` together, and a write to an existing key
  overwrites it, so there is one call rather than a create and an update, and
  no 404 to handle on the first write of a rotation.
  """
  @spec put_secret(Client.t(), store(), id(), String.t(), String.t()) :: outcome()
  def put_secret(client, store, id, key, value) when store in [:environments, :vaults] do
    void(client, "POST", "/api/#{store}/#{escape(id)}/secrets",
      body: %{"key" => key, "value" => value}
    )
  end

  @doc "`DELETE /api/{environments,vaults}/:id/secrets/:key`."
  @spec delete_secret(Client.t(), store(), id(), String.t()) :: outcome()
  def delete_secret(client, store, id, key) when store in [:environments, :vaults],
    do: void(client, "DELETE", "/api/#{store}/#{escape(id)}/secrets/#{escape(key)}")

  @doc "`GET /api/{environments,vaults}/:id/secrets`: keys and `updated_at`, never values."
  @spec secret_keys(Client.t(), store(), id()) :: result([record()])
  def secret_keys(client, store, id) when store in [:environments, :vaults],
    do: list(client, "/api/#{store}/#{escape(id)}/secrets")

  # ── conversations ─────────────────────────────────────────────────────

  @doc """
  `GET /api/conversations`, optionally for one agent.

  The list carries `sandbox_id` but serves `"sandbox": null`; the embedded
  object is a detail-endpoint field. Anything wanting `sprite_name` has to ask
  `sandbox/2` and pay for the extra call.
  """
  @spec list_conversations(Client.t(), id() | nil) :: result([Shapes.Conversation.t()])
  def list_conversations(client, agent_id \\ nil) do
    with {:ok, raw} <- list(client, "/api/conversations", query: [agent_id: agent_id]) do
      {:ok, Shapes.conversations(raw)}
    end
  end

  @doc "`GET /api/conversations/:id`, sandbox embedded."
  @spec get_conversation(Client.t(), id()) :: result(Shapes.Conversation.t())
  def get_conversation(client, id) do
    with {:ok, raw} <-
           call(client, "GET", "/api/conversations/#{escape(id)}", fn http ->
             Fountain.Conversation.get(conversation(http, id))
           end) do
      {:ok, Shapes.conversation(raw)}
    end
  end

  @doc """
  Open a conversation on a project's machine.

  The whole identity goes on every attach, not half of it. A disk is built for
  `(agent, environment, vault)`, and naming only the agent asks for a
  *different* identity, one with no environment and no vault, which Fountain
  refuses as `sandbox_identity_mismatch`. This is the single most expensive
  thing to get wrong in the app: it does not fail loudly, it hands you a
  second machine.

  `attrs`: `:agent_id` and `:channel_id` (required), `:environment_id`,
  `:vault_id`, `:sandbox_id`, `:title`, `:prompt`.

  `:prompt` is the first turn, sent in the same call. Not an optimisation:
  every app in this suite that starts a *fresh* conversation sends its prompt
  here, and paddock sending it separately is the one difference that made
  provisioning a machine start answering 422. So a track's opening turn rides
  along with the launch that provisions the box; only an attach to a box that
  already exists prompts separately.

  With a `:sandbox_id` the conversation attaches; without one it provisions
  with `sandbox_mode: "persistent"`, which is what makes the disk the
  identity's home rather than this one conversation's. Attaching ignores the
  mode.

  `fresh: true`, always. A `channel_id` on create makes Fountain hand back the
  latest live conversation for the same (agent, vault, channel) and answer 200
  instead of opening one. Right for a chat harness, wrong here, where a slug is
  already unique per live track and a resume would quietly give two tracks one
  conversation. The `channel_id` is still sent: it is the track's durable
  membership of its machine, the name Fountain files the conversation under.
  """
  @spec create_conversation(Client.t(), map()) :: result(Shapes.Conversation.t())
  def create_conversation(client, attrs) do
    body =
      %{
        "agent_id" => Map.fetch!(attrs, :agent_id),
        "channel_id" => Map.fetch!(attrs, :channel_id),
        "fresh" => true
      }
      |> optional("environment_id", attrs[:environment_id])
      |> optional("vault_id", attrs[:vault_id])
      |> sandbox_identity(attrs[:sandbox_id])
      |> optional("title", attrs[:title])
      |> optional("prompt", attrs[:prompt])

    with {:ok, raw} <- data(client, "POST", "/api/conversations", body: body) do
      {:ok, Shapes.conversation(raw)}
    end
  end

  @doc """
  `POST /api/conversations/:id/prompts`: one turn, with optional images as
  `%{data: base64, media_type: ...}`.
  """
  @spec prompt(Client.t(), id(), String.t(), [map()]) :: outcome()
  def prompt(client, id, text, images \\ []) do
    body = %{"prompt" => text} |> optional("images", if(images == [], do: nil, else: images))
    void(client, "POST", "/api/conversations/#{escape(id)}/prompts", body: body)
  end

  @doc "`POST /api/conversations/:id/interrupt`: stop the running turn."
  @spec interrupt(Client.t(), id()) :: outcome()
  def interrupt(client, id) do
    call(client, "POST", "/api/conversations/#{escape(id)}/interrupt", fn http ->
      Fountain.Conversation.interrupt(conversation(http, id))
    end)
  end

  @doc "`POST /api/conversations/:id/terminate`: end the conversation."
  @spec terminate(Client.t(), id()) :: outcome()
  def terminate(client, id) do
    call(client, "POST", "/api/conversations/#{escape(id)}/terminate", fn http ->
      Fountain.Conversation.terminate(conversation(http, id))
    end)
  end

  @doc "`GET /api/conversations/:id/turns`: the prompts, which live apart from the output."
  @spec turns(Client.t(), id()) :: result([Shapes.Turn.t()])
  def turns(client, id) do
    with {:ok, raw} <-
           call(client, "GET", "/api/conversations/#{escape(id)}/turns", fn http ->
             Fountain.Conversation.turns(conversation(http, id))
           end) do
      {:ok, Shapes.turns(raw)}
    end
  end

  @doc """
  One stored page of `GET /api/conversations/:id/events`.

  Options: `:after` (the cursor), `:limit` (default 1000), `:blocks` (ask
  Fountain for server-parsed blocks; off by default, the transcript parses
  ACP itself).
  """
  @spec events_page(Client.t(), id(), keyword()) :: result(events_page())
  def events_page(client, id, opts \\ []) do
    path = "/api/conversations/#{escape(id)}/events"

    query = [
      limit: Keyword.get(opts, :limit, @page_limit),
      after: opts[:after],
      blocks: if(opts[:blocks], do: "true")
    ]

    call(client, "GET", path, fn http ->
      with {:ok, page} <- HTTP.request(http, "GET", path, query: query) do
        {:ok, page_of(page, opts[:after])}
      end
    end)
  end

  @doc """
  Every stored event, reading every page so long tracks retain their later
  replies. Deduplicated by id and sorted by id. Options as `events_page/3`
  less `:after`.
  """
  @spec events(Client.t(), id(), keyword()) :: result([record()])
  def events(client, id, opts \\ []) do
    if Client.configured?(client),
      do: collect_events(client, id, Keyword.delete(opts, :after), nil, %{}),
      else: {:error, :unconfigured}
  end

  @doc """
  The live transcript, as a lazy `Enumerable` of decoded events.

  `GET /api/conversations/:id/stream`, with the SDK's reconnect: a dropped
  connection is reopened with `Last-Event-ID` set to the newest id seen, and
  the retry budget starts over whenever a connection delivered data. Pass
  `:after` to resume from an id you already hold, as the browser's
  `EventSource` did with the id of the last frame it absorbed. Frames are named
  after the event's `kind` (`output` a byte the machine produced, `stage` a
  change of state) and arrive here as the maps the `/events` pages serve, id
  included, so a consumer can deduplicate against the page it loaded first.

  Enumerating the stream raises `Fountain.Error` when it fails for good;
  `each_event/4` turns that into a tuple. Other options pass through to
  `Fountain.SSE.stream_events/3` (`:max_retries`, `:retry_delay`, `:deadline`,
  `:idle_timeout`, `:streams`, `:blocks`, `:wait`).
  """
  @spec stream_events(Client.t(), id(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, :unconfigured}
  def stream_events(client, id, opts \\ [])
  def stream_events(%Client{http: nil}, _id, _opts), do: {:error, :unconfigured}

  def stream_events(%Client{http: http}, id, opts),
    do: {:ok, Fountain.SSE.stream_events(http, escape(id), Keyword.put_new(opts, :blocks, false))}

  @doc """
  Run `fun` for every live event until it returns `:halt` or the stream ends.

  Returns `:ok` when it stopped cleanly and `{:error, %Error{}}` when Fountain
  refused the stream or it could not be kept open; the caller reconnects with
  `after:` set to the last id it saw.
  """
  @spec each_event(Client.t(), id(), (record() -> :halt | term()), keyword()) :: outcome()
  def each_event(client, id, fun, opts \\ []) do
    with {:ok, stream} <- stream_events(client, id, opts) do
      Enum.reduce_while(stream, :ok, fn event, :ok -> step(fun, event) end)
    end
  rescue
    error in Fountain.Error ->
      {:error, fail(error, "GET", "/api/conversations/#{escape(id)}/stream")}
  end

  # ── reading the machine, for free ─────────────────────────────────────

  @doc """
  One sandbox, in full.

  The only place `sprite_name` actually appears. `GET /api/conversations`
  carries a `sandbox_id` but serves `"sandbox": null`, so a terminal that read
  the list would conclude, wrongly and permanently, that this machine is not
  on Sprites.
  """
  @spec sandbox(Client.t(), id()) :: result(Shapes.Sandbox.t())
  def sandbox(client, id) do
    with {:ok, raw} <- data(client, "GET", "/api/sandboxes/#{escape(id)}") do
      {:ok, Shapes.sandbox(raw)}
    end
  end

  @doc "`GET /api/sandboxes/:id/files?path=`: one directory. Does not wake a parked box."
  @spec listing(Client.t(), id(), String.t()) :: result(record())
  def listing(client, sandbox_id, path),
    do: data(client, "GET", "/api/sandboxes/#{escape(sandbox_id)}/files", query: [path: path])

  @doc "`GET /api/sandboxes/:id/file?path=`: one file's bytes, text or base64, redacted."
  @spec file(Client.t(), id(), String.t()) :: result(record())
  def file(client, sandbox_id, path),
    do: data(client, "GET", "/api/sandboxes/#{escape(sandbox_id)}/file", query: [path: path])

  @doc "`GET /api/sandboxes/:id/diff?path=`: `git diff` of the repository at `path`."
  @spec diff(Client.t(), id(), String.t()) :: result(record())
  def diff(client, sandbox_id, path),
    do: data(client, "GET", "/api/sandboxes/#{escape(sandbox_id)}/diff", query: [path: path])

  # ── plumbing ──────────────────────────────────────────────────────────

  # A call whose body is `{data: ...}`, unwrapped, which is every one of them.
  # A body without the wrapper is handed back whole, as the TypeScript did.
  defp data(client, method, path, opts \\ []) do
    call(client, method, path, fn http ->
      with {:ok, body} <- HTTP.request(http, method, path, opts), do: {:ok, unwrap(body)}
    end)
  end

  defp list(client, path, opts \\ []) do
    call(client, "GET", path, fn http ->
      with {:ok, body} <- HTTP.request(http, "GET", path, opts), do: {:ok, items(unwrap(body))}
    end)
  end

  defp items(value) when is_list(value), do: value
  defp items(_value), do: []

  defp step(fun, event), do: if(fun.(event) == :halt, do: {:halt, :ok}, else: {:cont, :ok})

  defp void(client, method, path, opts \\ []) do
    call(client, method, path, fn http ->
      with {:ok, _} <- HTTP.request(http, method, path, opts), do: :ok
    end)
  end

  defp call(%Client{http: nil}, _method, _path, _fun), do: {:error, :unconfigured}

  defp call(%Client{http: http}, method, path, fun) do
    case fun.(http) do
      :ok -> :ok
      {:ok, value} -> {:ok, value}
      {:error, %Fountain.Error{} = error} -> {:error, fail(error, method, path)}
    end
  end

  # The path and the status, never the body we sent: it may be a secret value
  # on its way to /secrets. Upstream's own message is usually the useful half
  # of a failure, but it is derived from Fountain's response body, and a
  # rejected secret is exactly the kind of value an API echoes back to say
  # what was wrong with it -- so on those paths the status is the whole log.
  defp fail(%Fountain.Error{} = error, method, path) do
    ours = Error.from_sdk(error)

    if ours.status >= 400 do
      detail = if secret_path?(path), do: "", else: ": #{ours.message}"
      Logger.error("ravix: fountain #{ours.status} on #{method} #{path}#{detail}")
    end

    ours
  end

  defp secret_path?(path), do: String.contains?(path, "/secrets")

  defp conversation(http, id), do: Fountain.Conversation.new(http, escape(id))

  defp collect_events(client, id, opts, after_cursor, seen) do
    with {:ok, page} <- events_page(client, id, Keyword.put(opts, :after, after_cursor)) do
      seen = Enum.reduce(page.events, seen, &Map.put(&2, &1["id"], &1))

      cond do
        not page.has_more ->
          {:ok, seen |> Map.values() |> Enum.sort_by(& &1["id"])}

        is_nil(page.next_cursor) or
            (not is_nil(after_cursor) and page.next_cursor <= after_cursor) ->
          {:error,
           %Error{
             status: 0,
             code: "pagination_stalled",
             message: "Fountain event pagination did not advance",
             kind: :api
           }}

        true ->
          collect_events(client, id, opts, page.next_cursor, seen)
      end
    end
  end

  defp page_of(%{"data" => events} = page, after_cursor) when is_list(events) do
    meta = if is_map(page["meta"]), do: page["meta"], else: %{}

    %{
      events: events,
      has_more: meta["has_more"] == true,
      next_cursor:
        if(is_integer(meta["next_cursor"]), do: meta["next_cursor"], else: after_cursor)
    }
  end

  defp page_of(_page, after_cursor), do: %{events: [], has_more: false, next_cursor: after_cursor}

  defp sandbox_identity(body, nil), do: Map.put(body, "sandbox_mode", "persistent")
  defp sandbox_identity(body, ""), do: Map.put(body, "sandbox_mode", "persistent")
  defp sandbox_identity(body, sandbox_id), do: Map.put(body, "sandbox_id", sandbox_id)

  defp optional(body, _key, nil), do: body
  defp optional(body, _key, ""), do: body
  defp optional(body, key, value), do: Map.put(body, key, value)

  defp unwrap(%{"data" => data}), do: data
  defp unwrap(body), do: body

  defp escape(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
