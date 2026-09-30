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
  `{:error, {:unconfigured, :fountain}}` from every call and never crashes;
  `Ravix.Providers` says why that shape and why no context rewrites it.

  Over `fountain_sdk`: `Fountain.HTTP` carries the bearer header, the JSON
  encoding and the error structs; `Fountain.Conversation` the per-conversation
  reads and signals; `Fountain.SSE` the live transcript with its reconnect.
  The resource modules (`Fountain.Agents`, `Fountain.Environments`, ...) are
  not used: they resolve names through a per-process ETS cache, and Ravix only
  ever addresses records by id, from whichever process is handling a request.

  Failures are logged with the path and the status and nothing else: the body
  may be a secret value on its way to `/secrets`, or somebody's subscription
  token on its way to a credential set.
  """

  require Logger

  alias Fountain.HTTP
  alias Ravix.Fountain.{Client, Error, Image, Launch, Shapes}
  alias Ravix.Trace

  @type id :: String.t()
  @type store :: :environments | :vaults
  @type record :: %{optional(String.t()) => term()}
  @type failure :: Error.t() | {:unconfigured, :fountain}
  @type result(value) :: {:ok, value} | {:error, failure()}
  @type outcome :: :ok | {:error, failure()}
  @type events_page :: %{
          events: [record()],
          next_cursor: integer() | nil,
          has_more: boolean(),
          window: Shapes.EventWindow.t() | nil
        }

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

  @doc "Atomic server-side secret snapshot. Values are never returned. Requires Fountain #2527."
  @spec copy_vault(Client.t(), id(), map()) :: result(Shapes.Vault.t())
  def copy_vault(client, id, attrs) do
    with {:ok, raw} <- data(client, "POST", "/api/vaults/#{escape(id)}/copy", body: attrs),
         do: {:ok, Shapes.vault(raw)}
  end

  @doc "List owned credential containers for operation-identity reconciliation."
  @spec vaults(Client.t()) :: result([Shapes.Vault.t()])
  def vaults(client) do
    with {:ok, rows} <- list(client, "/api/vaults"),
         do: {:ok, Enum.map(rows, &Shapes.vault/1)}
  end

  @doc "Read a credential container without returning values."
  def get_vault(client, id) do
    with {:ok, raw} <- data(client, "GET", "/api/vaults/#{escape(id)}"),
         do: {:ok, Shapes.vault(raw)}
  end

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

  # ── who pays for the model ────────────────────────────────────────────

  @typedoc """
  The four things a credential set can hold, in Fountain's own spelling. They
  are a path segment, so they are a closed list here rather than a string a
  caller composes.
  """
  @type provider ::
          :claude_code_oauth_token | :anthropic_api_key | :openai_api_key | :gemini_api_key

  @providers ~w(claude_code_oauth_token anthropic_api_key openai_api_key gemini_api_key)a

  @doc """
  `POST /api/account/inference-credential-sets`: an empty, named set.

  Ravix is one Fountain account holding everybody's machines, so a person's
  own subscription cannot be the *account's* credential. A set is what Fountain
  offers instead: a named group of provider credentials on this account, which
  an agent is pointed at with `inference_credential_id`. One per person; see
  `Ravix.Accounts.Inference`.

  Names are unique on the account, and a duplicate is a 422. Needs a
  full-scope key, and a Fountain of v0.17 or newer: an older one answers 404.
  """
  @spec create_credential_set(Client.t(), String.t()) :: result(record())
  def create_credential_set(client, name),
    do: data(client, "POST", "/api/account/inference-credential-sets", body: %{"name" => name})

  @doc "`GET /api/account/inference-credential-sets`: each with the `providers` it holds, never a value."
  @spec credential_sets(Client.t()) :: result([record()])
  def credential_sets(client), do: list(client, "/api/account/inference-credential-sets")

  @doc """
  Write one credential into a set.

  Fountain checks the value against the provider before storing it unless told
  not to, so a 422 here usually means the provider refused the key, and a 502
  or 504 that the provider could not be reached to ask.

  The second call in this module whose body must never be logged; the path
  names `/credentials/`, which `fail/3` treats as it does `/secrets`.

  **Any write to a set invalidates every conversation already running on it.**
  Fountain binds a conversation to the set's revision and refuses the next
  prompt with `inference_source_changed` rather than quietly spending a
  different credential. The remedy is a new conversation.
  """
  @spec put_credential(Client.t(), id(), provider(), String.t()) :: outcome()
  def put_credential(client, set_id, provider, value) when provider in @providers do
    void(client, "PUT", credential_path(set_id, provider), body: %{"value" => value})
  end

  @doc "`DELETE .../credentials/:provider`. Also bumps the set's revision; see `put_credential/4`."
  @spec delete_credential(Client.t(), id(), provider()) :: outcome()
  def delete_credential(client, set_id, provider) when provider in @providers,
    do: void(client, "DELETE", credential_path(set_id, provider))

  defp credential_path(set_id, provider),
    do: "/api/account/inference-credential-sets/#{escape(set_id)}/credentials/#{provider}"

  # ── a ChatGPT subscription ────────────────────────────────────────────
  #
  # The fourth thing a set can point at is not a value anybody pastes. A
  # person signs in to ChatGPT with a device code, Fountain keeps the tokens
  # and renews them, and the subscription is a *grant* on this account that a
  # set names by id. Fountain's `docs/build/chatgpt-subscriptions.md` is the
  # contract these eight functions follow.

  @chatgpt "/api/account/chatgpt-subscriptions"

  @doc """
  `POST /api/account/chatgpt-subscriptions/attempts`: start a device-code
  sign-in. `%{name: name}` links a new subscription under that name;
  `%{grant_id: id}` reconnects one the account already holds.

  The reply is the attempt: `id`, `state` (`pending`), `user_code`,
  `verification_url`, `poll_interval` in seconds, `expires_at` (fifteen
  minutes out). The code and the URL are shown only to the person who
  started the attempt, and nobody else, because whoever types the code at
  that URL links *their* ChatGPT account to *this* Fountain account.

  Refusals worth telling apart: `404 chatgpt_subscriptions_not_enabled`
  (linking is off for this account, or the Fountain predates it), `409
  chatgpt_link_attempt_pending` with the open `attempt_id`, `409
  chatgpt_link_attempts_exceeded`, `409 chatgpt_grant_limit_reached`, `429
  chatgpt_link_attempts_rate_limited`, `502 chatgpt_auth_unreachable`.
  """
  @spec start_chatgpt_link(Client.t(), %{name: String.t()} | %{grant_id: id()}) ::
          result(record())
  def start_chatgpt_link(client, %{name: name}) when is_binary(name),
    do: data(client, "POST", "#{@chatgpt}/attempts", body: %{"name" => name})

  def start_chatgpt_link(client, %{grant_id: grant_id}) when is_binary(grant_id),
    do: data(client, "POST", "#{@chatgpt}/attempts", body: %{"grant_id" => grant_id})

  @doc """
  `GET /api/account/chatgpt-subscriptions/attempts/:id`: the attempt as it
  stands. Reads a row; Fountain is the one polling ChatGPT.

  `state` moves once, from `pending` to `completed`, `cancelled`, `expired`
  or `failed`, and stays readable afterwards. A completed attempt carries the
  subscription's id in `result_grant_id`; a failed one carries
  `failure.reason`.
  """
  @spec chatgpt_link(Client.t(), id()) :: result(record())
  def chatgpt_link(client, attempt_id),
    do: data(client, "GET", "#{@chatgpt}/attempts/#{escape(attempt_id)}")

  @doc "`GET .../attempts`: the account's *pending* attempts, oldest first, each with its code."
  @spec pending_chatgpt_links(Client.t()) :: result([record()])
  def pending_chatgpt_links(client), do: list(client, "#{@chatgpt}/attempts")

  @doc "`DELETE .../attempts/:id`: end a pending attempt. A code approved afterwards stores nothing."
  @spec cancel_chatgpt_link(Client.t(), id()) :: result(record())
  def cancel_chatgpt_link(client, attempt_id),
    do: data(client, "DELETE", "#{@chatgpt}/attempts/#{escape(attempt_id)}")

  @doc """
  `GET /api/account/chatgpt-subscriptions`: every subscription the account
  holds, each with `id`, `name`, `status`, `plan_type`, `account_email`,
  `exhausted_until`. Never a token.
  """
  @spec chatgpt_subscriptions(Client.t()) :: result([record()])
  def chatgpt_subscriptions(client), do: list(client, @chatgpt)

  @doc """
  `POST /api/account/chatgpt-subscriptions/:id/disconnect`: forget the
  sign-in's tokens and keep the row.

  Every set that names the subscription starts refusing Codex runs on it
  (`chatgpt_grant_unusable`, `disconnected`), and a later sign-in for the
  same `grant_id` reconnects it rather than making a second. Fountain cannot
  sign the device out at OpenAI; the person does that in their ChatGPT
  account. A subscription that is already disconnected is a `409`.
  """
  @spec disconnect_chatgpt_subscription(Client.t(), id()) :: result(record())
  def disconnect_chatgpt_subscription(client, grant_id),
    do: data(client, "POST", "#{@chatgpt}/#{escape(grant_id)}/disconnect")

  @doc """
  `DELETE /api/account/chatgpt-subscriptions/:id`: forget the subscription
  altogether, the row included.

  Unlike `disconnect_chatgpt_subscription/2` this leaves nothing to reconnect,
  and it frees the ChatGPT account to be linked again --- which is the only
  reason Ravix calls it. A grant a set still names must not be deleted: the
  set goes on naming an id that is gone, and Codex on it refuses every run.
  `Ravix.Accounts.Inference` therefore deletes only a grant it has just
  confirmed no set names and no Ravix login is named on.
  """
  @spec delete_chatgpt_subscription(Client.t(), id()) :: outcome()
  def delete_chatgpt_subscription(client, grant_id),
    do: void(client, "DELETE", "#{@chatgpt}/#{escape(grant_id)}")

  @doc """
  `PATCH /api/account/chatgpt-subscriptions/:id` with `name`: rename the
  subscription, without touching what it holds or which sets name it.

  Names are how Ravix tells one person's grant from another's
  (`ravix:<ravix user id>`), and a set names a grant by *id*, so a rename
  changes who a grant is understood to belong to and nothing about what it
  can do. The one caller is the operator hand-over in
  `Ravix.Accounts.Inference.move_subscription/3`.
  """
  @spec rename_chatgpt_subscription(Client.t(), id(), String.t()) :: result(record())
  def rename_chatgpt_subscription(client, grant_id, name) when is_binary(name),
    do: data(client, "PATCH", "#{@chatgpt}/#{escape(grant_id)}", body: %{"name" => name})

  @doc """
  `PATCH /api/account/inference-credential-sets/:id` with `chatgpt_grant_id`:
  make `grant_id` what the set's Codex runs use, or `nil` to stop naming one.

  This is the switch. A linked subscription does nothing until a set names
  it, and once one does, Codex on that set runs on the subscription and on
  nothing else: an unusable subscription refuses the run
  (`chatgpt_grant_unusable`) rather than falling back to a key. Only Codex
  reads the grant; any other OpenAI consumer still wants an `openai_api_key`.

  **Naming a grant bumps the set's revision like any other write** and ends
  the conversations already running on it; see `put_credential/4`.
  """
  @spec name_chatgpt_subscription(Client.t(), id(), id() | nil) :: result(record())
  def name_chatgpt_subscription(client, set_id, grant_id)
      when is_binary(grant_id) or is_nil(grant_id) do
    data(client, "PATCH", "/api/account/inference-credential-sets/#{escape(set_id)}",
      body: %{"chatgpt_grant_id" => grant_id}
    )
  end

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
  Open a conversation on a sandbox.

  The whole identity goes on every attach, not half of it. A disk is built for
  `(agent, environment, vault)`, and naming only the agent asks for a
  *different* identity, one with no environment and no vault, which Fountain
  refuses as `sandbox_identity_mismatch`. This is the single most expensive
  thing to get wrong in the app: it does not fail loudly, it hands you a
  second machine.

  An other-runtime project agent may attach as a guest with `sandbox_id` and
  the same user, environment and vault. Another agent of the home's runtime is
  refused; many conversations of the home agent are allowed. The provider
  enforces this rule, not a client-side guess from cached runtime metadata.
  A failed create with `Error.unknown_outcome?/1` must be reconciled before
  retrying: `fresh: true` does not make allocation idempotent.

  `Ravix.Fountain.Launch` names all seven fields and enforces every one of
  them, including the ones that are optional *on the wire*: the identity
  rule above is only a rule if a caller cannot leave half of it out, and a
  map let them.

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
  @spec create_conversation(Client.t(), Launch.t()) :: result(Shapes.Conversation.t())
  def create_conversation(client, %Launch{} = launch) do
    body =
      %{
        "agent_id" => launch.agent_id,
        "channel_id" => launch.channel_id,
        "fresh" => true
      }
      |> optional("environment_id", launch.environment_id)
      |> optional("vault_id", launch.vault_id)
      |> sandbox_identity(launch.sandbox_id)
      |> optional("title", launch.title)
      |> optional("prompt", launch.prompt)
      |> optional("model", launch.model)
      |> optional("inference_credential_id", launch.inference_credential_id)

    with {:ok, raw} <- data(client, "POST", "/api/conversations", body: body) do
      {:ok, Shapes.conversation(raw)}
    end
  end

  @doc """
  `POST /api/conversations/:id/prompts`: one turn, with optional images as
  `%{data: base64, media_type: ...}`.

  Options: `:client_request_id`, the caller's name for this submission.
  Fountain copies it onto the turn the prompt opens, so a caller that could
  not tell whether the POST arrived can find out from `turns/2` afterwards.
  It is a correlation and not an idempotency key: sending the same one twice
  opens two turns. `:session_config`, the ACP session config options for
  this turn only (ADR 0062), a map of the runtime's option ids to strings or
  booleans; an empty map is not sent. A Fountain before the field ignores it.
  """
  @spec prompt(Client.t(), id(), String.t(), [map()], keyword()) :: outcome()
  def prompt(client, id, text, images \\ [], opts \\ []) do
    body =
      %{"prompt" => text}
      |> optional("images", if(images == [], do: nil, else: images))
      |> optional("client_request_id", opts[:client_request_id])
      |> optional("session_config", nonempty(opts[:session_config]))

    void(client, "POST", "/api/conversations/#{escape(id)}/prompts", body: body)
  end

  @doc "`POST /api/conversations/:id/interrupt`: stop the running turn."
  @spec interrupt(Client.t(), id()) :: outcome()
  def interrupt(client, id) do
    call(client, "POST", "/api/conversations/#{escape(id)}/interrupt", fn http ->
      Fountain.Conversation.interrupt(conversation(http, id))
    end)
  end

  @doc """
  `POST /api/conversations/:id/reapply` naming only `model`: the model this
  one conversation runs from its next turn (Fountain ADR 0061).

  A string sets it and `nil` returns the conversation to its agent's model.
  Nothing else is named, so the agent, environment and vault keep their
  selection, which is also the only selection a shared machine accepts. The
  runtime session is kept, so the agent keeps its context.

  Fountain refuses with `conversation_busy` while a turn runs and with
  `inference_source_changed` when the model needs another credential than
  the one the conversation is pinned to; either way nothing changes.
  """
  @spec set_model(Client.t(), id(), String.t() | nil) :: result(Shapes.Conversation.t())
  def set_model(client, id, model) when is_binary(model) or is_nil(model) do
    path = "/api/conversations/#{escape(id)}/reapply"

    with {:ok, raw} <- data(client, "POST", path, body: %{"model" => model}) do
      {:ok, Shapes.conversation(raw)}
    end
  end

  @doc "`POST /api/conversations/:id/terminate`: end the conversation."
  @spec terminate(Client.t(), id()) :: outcome()
  def terminate(client, id) do
    call(client, "POST", "/api/conversations/#{escape(id)}/terminate", fn http ->
      Fountain.Conversation.terminate(conversation(http, id))
    end)
  end

  @doc "The retained bytes of one prompt image. Credentials stay on the server."
  @spec turn_image(Client.t(), id(), id(), non_neg_integer()) ::
          result(Image.t()) | {:error, :not_found}
  def turn_image(client, conversation_id, turn_id, position) do
    path =
      "/api/conversations/#{escape(conversation_id)}/turns/#{escape(turn_id)}/images/#{position}"

    with {:ok, bytes} <-
           call(client, "GET", path, &HTTP.request(&1, "GET", path, accept: "image/*")) do
      Image.decode(bytes)
    end
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
  ACP itself), `:prompts` (put each turn's prompt on its `turn`/`started`
  event as a `prompt` block).

  Fountain only fills `prompts` together with `blocks`, so `:prompts` turns
  `:blocks` on as well. That is also every output event's blocks, which
  nothing here reads; `Ravix.Tracks.Transcript.Event.from/1` keeps the
  prompt and drops the rest. Only this feed carries prompts: the stream
  never does.

  Newest first (managoat/fountain#2531): `order: :desc` serves the newest
  events, newest first, and `next_cursor` is then the page's oldest id, to
  pass back as `:before`. `whole_turns: true` (only with `:desc`) never ends
  a page inside a turn, so a page can exceed `:limit`. `window` is the
  response's `page` object as a `Shapes.EventWindow`, or `nil` from a
  Fountain older than #2531, which ignores the new parameters and answers
  the oldest page, oldest first.
  """
  @spec events_page(Client.t(), id(), keyword()) :: result(events_page())
  def events_page(client, id, opts \\ []) do
    path = "/api/conversations/#{escape(id)}/events"
    desc? = opts[:order] == :desc

    query = [
      limit: Keyword.get(opts, :limit, @page_limit),
      after: opts[:after],
      before: opts[:before],
      order: if(desc?, do: "desc"),
      whole_turns: if(desc? and opts[:whole_turns], do: "true"),
      blocks: if(opts[:blocks] || opts[:prompts], do: "true"),
      prompts: if(opts[:prompts], do: "true")
    ]

    call(client, "GET", path, fn http ->
      with {:ok, page} <- HTTP.request(http, "GET", path, query: query) do
        {:ok, page_of(page, if(desc?, do: opts[:before], else: opts[:after]))}
      end
    end)
  end

  @doc """
  Every stored event, reading every page so long tracks retain their later
  replies. Deduplicated by id and sorted by id. Options as `events_page/3`;
  `:after` limits catch-up to events newer than a held cursor. Always reads
  forward: `:order`, `:before` and `:whole_turns` are page options only.
  `:from` is a first forward page already read, which the log continues
  from instead of reading it again.
  """
  @spec events(Client.t(), id(), keyword()) :: result([record()])
  def events(client, id, opts \\ []) do
    {first, opts} = Keyword.pop(opts, :from)
    opts = Keyword.drop(opts, [:order, :before, :whole_turns])

    cond do
      not Client.configured?(client) ->
        {:error, {:unconfigured, :fountain}}

      first ->
        seen = Map.new(first.events, &{&1["id"], &1})
        Trace.annotate(%{"ravix.event_pages" => 1})

        if first.has_more,
          do: collect_events(client, id, opts, first.next_cursor, seen, 1),
          else: {:ok, seen |> Map.values() |> Enum.sort_by(& &1["id"])}

      true ->
        collect_events(client, id, Keyword.delete(opts, :after), opts[:after], %{}, 0)
    end
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
          {:ok, Enumerable.t()} | {:error, {:unconfigured, :fountain}}
  def stream_events(client, id, opts \\ [])
  def stream_events(%Client{http: nil}, _id, _opts), do: {:error, {:unconfigured, :fountain}}

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

  @doc """
  `GET /api/sandboxes`, optionally filtered by provider status strings.

  Identity fields let lifecycle callers reconcile an uncertain create against
  their persisted intent. Listing is evidence, not an allocation idempotency key.
  """
  @spec sandboxes(Client.t(), keyword()) :: result([Shapes.Sandbox.t()])
  def sandboxes(client, opts \\ []) do
    status = opts[:status]
    status = if is_list(status), do: Enum.join(status, ","), else: status

    with {:ok, raw} <- list(client, "/api/sandboxes", query: [status: status]) do
      {:ok, Enum.map(raw, &Shapes.sandbox/1)}
    end
  end

  @doc """
  `DELETE /api/sandboxes/:id`, the SDK's `reset_sandbox/2` endpoint.

  `:ok` means the request succeeded or Fountain explicitly said this sandbox
  is already gone. Confirm completion with `sandbox/2` before provisioning a
  replacement; an accepted request is not proof that deletion has completed.
  A generic 404 may mean the endpoint is unsupported and is not success.

  Connection errors, timeouts and 5xx have unknown outcomes. No mutation is
  automatically retried here. Callers persist intent and reconcile status;
  `Error.unknown_outcome?/1` identifies errors needing that treatment.
  """
  @spec reset_sandbox(Client.t(), id()) :: outcome()
  def reset_sandbox(client, id) do
    case void(client, "DELETE", "/api/sandboxes/#{escape(id)}") do
      {:error, %Error{} = error} = failure ->
        if Error.sandbox_gone?(error), do: :ok, else: failure

      result ->
        result
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

  defp call(%Client{http: nil}, _method, _path, _fun), do: {:error, {:unconfigured, :fountain}}

  defp call(%Client{http: http}, method, path, fun) do
    # Every Fountain request funnels through here, which is why the span is
    # here and not on the thirty public functions above it. Deliberately *not*
    # on `stream_events/3`: that one hands back a lazy stream rather than going
    # through `call/4`, and `Ravix.Tracks.Follower` keeps it open for as long
    # as anybody anywhere is looking at a transcript. A span around an
    # hours-long stream is never exported and never ends.
    #
    # The path is an attribute rather than part of the span name -- it carries
    # ids, so a name built from it would be a new name per conversation. It is
    # the same string `fail/3` already logs, so nothing new is disclosed here:
    # a secret's *name* can appear in a path, its value cannot.
    Trace.span(
      "fountain.request",
      %{"http.request.method" => method, "url.path" => path},
      fn ->
        case fun.(http) do
          :ok -> :ok
          {:ok, value} -> {:ok, value}
          {:error, %Fountain.Error{} = error} -> {:error, fail(error, method, path)}
        end
      end
    )
  end

  # The path and the status, never the body we sent: it may be a secret value
  # on its way to /secrets. Upstream's own message is usually the useful half
  # of a failure, but it is derived from Fountain's response body, and a
  # rejected secret is exactly the kind of value an API echoes back to say
  # what was wrong with it -- so on those paths the status is the whole log.
  defp fail(%Fountain.Error{} = error, method, path) do
    ours = Error.from_sdk(error)

    if ours.status >= 400 and not Error.sandbox_suspended?(ours) do
      detail = if sensitive_path?(path), do: "", else: ": #{ours.message}"
      Logger.error("ravix: fountain #{ours.status} on #{method} #{path}#{detail}")
    end

    ours
  end

  # Environment failures can echo readable values too; they belong in the
  # settings response, never in operational logs or telemetry.
  defp sensitive_path?(path),
    do:
      String.contains?(path, "/secrets") or String.contains?(path, "/credentials/") or
        String.starts_with?(path, "/api/environments")

  defp conversation(http, id), do: Fountain.Conversation.new(http, escape(id))

  defp collect_events(client, id, opts, after_cursor, seen, pages) do
    with {:ok, page} <- events_page(client, id, Keyword.put(opts, :after, after_cursor)) do
      seen = Enum.reduce(page.events, seen, &Map.put(&2, &1["id"], &1))
      Trace.annotate(%{"ravix.event_pages" => pages + 1})

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
          collect_events(client, id, opts, page.next_cursor, seen, pages + 1)
      end
    end
  end

  defp page_of(%{"data" => events} = page, cursor) when is_list(events) do
    meta = if is_map(page["meta"]), do: page["meta"], else: %{}

    %{
      events: events,
      has_more: meta["has_more"] == true,
      next_cursor: if(is_integer(meta["next_cursor"]), do: meta["next_cursor"], else: cursor),
      window: Shapes.event_window(page["page"])
    }
  end

  defp page_of(_page, cursor),
    do: %{events: [], has_more: false, next_cursor: cursor, window: nil}

  defp sandbox_identity(body, nil), do: Map.put(body, "sandbox_mode", "persistent")
  defp sandbox_identity(body, ""), do: Map.put(body, "sandbox_mode", "persistent")
  defp sandbox_identity(body, sandbox_id), do: Map.put(body, "sandbox_id", sandbox_id)

  defp nonempty(map) when is_map(map) and map_size(map) > 0, do: map
  defp nonempty(_map), do: nil

  defp optional(body, _key, nil), do: body
  defp optional(body, _key, ""), do: body
  defp optional(body, key, value), do: Map.put(body, key, value)

  defp unwrap(%{"data" => data}), do: data
  defp unwrap(body), do: body

  defp escape(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
