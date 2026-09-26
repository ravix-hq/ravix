defmodule Ravix.MachineCache do
  @moduledoc """
  One Fountain call per burst, not one per request.

  A project's machine is derived from its conversations rather than stored
  (see `Ravix.Tracks.machine_of/2` for why), and the derivation used to run
  on every request that needed it: the file, diff and listing routes, the
  terminal, the vitals readout every twenty seconds per viewer, the preview
  reconciler every fifteen. Each one listed the agent's conversations afresh.
  Across the deployed apps that was part of ~50,000 conversation-list calls
  an hour against production and a four-day database-pool incident
  (2026-09-07).

  So the list is memoised, briefly, per Fountain client and project:

    - **Short.** `ttl_ms/0` is a few seconds: enough that one screen's burst
      of requests costs one call, short enough that nothing on screen is
      stale for long.
    - **Coalesced.** Concurrent misses share one in-flight load.
    - **Invalidated on the writes that change the answer.** Opening a track
      (which may provision the machine), closing one, rebuilding or
      destroying the project: each calls `forget_project/1`.
    - **Refreshed by whoever needs it fresh.** Ordinary rail and thread lists
      use the memo. A turn event, explicit Refresh, or track detail refresh
      asks for `fresh: true`, and the answer is written through. A cached
      status or last-active time may be up to `ttl_ms/0` old. Read markers are
      not cached here: the reader's `:read` PubSub event clears unread dots
      immediately, and list reads compare the memo with current DB markers.
      A refresh is not a forget: it joins a load already in
      flight if that load started late enough, and otherwise the one
      load that follows it, so a hub event reaching every open page costs
      one or two Fountain calls rather than one per page. See
      `Ravix.Memo` for the rule.

  The sprite behind a sandbox never changes for a given sandbox id, so that
  lookup is memoised for longer; a "not a sprite" answer only briefly, since
  a sandbox mid-provisioning may not have one yet. A project's environment
  is memoised for the same minute and forgotten when settings are saved,
  which is the only thing that changes it. Fountain's catalog changes only
  when Fountain deploys, so it stands for five minutes; it is what a
  track's model menu offers, and a track opening should not wait on it.

  Values live in a public ETS table so a hit never touches the server; only
  misses go through the GenServer, which is where concurrent misses are
  joined onto one load. The load itself runs in a task under
  `Ravix.TaskSupervisor` so a slow Fountain blocks the waiters and nobody
  else. An entry is keyed on the client's base URL as well as the project:
  tests build a client per case, and a memo keyed on the project alone would
  hand one test another's answer. In production there is one client.
  """

  alias Ravix.Fountain
  alias Ravix.Fountain.Client
  alias Ravix.Fountain.Shapes
  alias Ravix.Fountain.Shapes.{Conversation, Sandbox}
  alias Ravix.MachineCache.Machine
  alias Ravix.Memo
  alias Ravix.Projects.Project

  @memo __MODULE__
  @ttl_ms 5_000
  @sprite_ttl_ms 60_000
  @environment_ttl_ms 60_000
  @catalog_ttl_ms 300_000

  @typedoc "A conversation as `GET /api/conversations` lists it."
  @type conversation :: Conversation.t()
  @typedoc "Which machine a project is on, or nil when no live conversation names one."
  @type machine :: Machine.t() | nil
  @type opts :: [fresh: boolean(), now_ms: integer()]

  @doc "How long a conversation list stands before it is re-read."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc "How long a sandbox's sprite name stands. It does not change."
  @spec sprite_ttl_ms() :: pos_integer()
  def sprite_ttl_ms, do: @sprite_ttl_ms

  @doc "How long an environment record stands before it is re-read."
  @spec environment_ttl_ms() :: pos_integer()
  def environment_ttl_ms, do: @environment_ttl_ms

  @doc "How long Fountain's catalog stands before it is re-read."
  @spec catalog_ttl_ms() :: pos_integer()
  def catalog_ttl_ms, do: @catalog_ttl_ms

  @doc false
  def child_spec(opts), do: Memo.child_spec(Keyword.put_new(opts, :name, @memo))

  @doc """
  The project's agent's conversations: from the memo while fresh, unless
  `fresh: true`, in which case only a list read no earlier than now will
  do -- the load in flight if it is that new, else one more -- and the memo
  is refreshed with it. Narrowed to the project's agent, never the whole
  account. A failed read is nobody's answer: the next caller retries.
  """
  @spec conversations(Client.t(), Project.t(), opts()) ::
          {:ok, [conversation()]} | {:error, Fountain.failure()}
  def conversations(%Client{} = client, %Project{} = project, opts \\ []) do
    memo(
      list_key(client, project),
      fn -> Fountain.list_conversations(client, project.agent_id) end,
      fn _ -> @ttl_ms end,
      opts
    )
  end

  @doc """
  The project's machine, read from its conversations. Nothing is stored.

  The list is enough for everything except the terminal: it carries
  `sandbox_id`, which is all the file, diff and listing routes need. It does
  *not* carry the sandbox object (`GET /api/conversations` serves
  `"sandbox": null`), so anything wanting `sprite_name` has to ask
  `sprite_for/3` and pay for the extra call.

  The newest live conversation with a sandbox wins. `fresh: true` is for the
  guards whose whole job is to notice the machine was replaced under them
  (the preview reconciler and the agent helper) and asks Fountain every time.
  """
  @spec machine_of(Client.t(), Project.t(), opts()) ::
          {:ok, machine()} | {:error, Fountain.failure()}
  def machine_of(%Client{} = client, %Project{} = project, opts \\ []) do
    with {:ok, all} <- conversations(client, project, opts) do
      newest =
        all
        |> Enum.filter(&(is_binary(&1.sandbox_id) and Shapes.live?(&1)))
        |> Shapes.newest()

      {:ok, if(newest, do: %Machine{sandbox_id: newest.sandbox_id})}
    end
  end

  @doc """
  The sprite behind a sandbox, or nil if it is not on Sprites at all.

  Made only by the panels that need a shell, and memoised per sandbox for a
  minute: a sandbox id names one machine, and its sprite does not change. A
  sandbox on another provider is a real answer rather than a failure (the
  terminal says so), which is why this is nil instead of an error, and why a
  Fountain failure reads as nil too.
  """
  @spec sprite_for(Client.t(), String.t(), opts()) :: String.t() | nil
  def sprite_for(%Client{} = client, sandbox_id, opts \\ []) do
    sprite_name(
      client,
      sandbox_id,
      fn ->
        case Fountain.sandbox(client, sandbox_id) do
          {:ok, %Sandbox{sprite_name: name}} when is_binary(name) and name != "" -> name
          _ -> nil
        end
      end,
      opts
    )
  end

  @doc "The sprite behind one sandbox, through `load`, memoised. Nil when it is not on Sprites."
  @spec sprite_name(Client.t(), String.t(), (-> String.t() | nil), opts()) :: String.t() | nil
  def sprite_name(%Client{} = client, sandbox_id, load, opts \\ []) when is_function(load, 0) do
    key = {client_id(client), :sprite, sandbox_id}

    case memo(key, fn -> {:ok, load.()} end, &if(&1, do: @sprite_ttl_ms, else: @ttl_ms), opts) do
      {:ok, name} -> name
      _ -> nil
    end
  end

  @doc """
  A project's environment record, memoised for a minute.

  `Ravix.Tracks.get/2` reads this for one boolean --- whether the project
  has a setup script, which decides whether the ribbon offers to add one ---
  and `get/2` runs on every refresh of every open track page. Uncached, that
  was a Fountain round trip per page per refresh for an answer that changes
  only when somebody saves settings.

  That save calls `forget_environment/1`, so the minute is the backstop for
  a change made on another instance rather than the thing keeping this
  current. `Ravix.Projects.Settings.get/2` deliberately does not come
  through here: the settings form is the page that edits the environment and
  must show what is actually stored.
  """
  @spec environment(Client.t(), String.t(), opts()) ::
          {:ok, map()} | {:error, Fountain.failure()}
  def environment(%Client{} = client, environment_id, opts \\ []) do
    memo(
      {client_id(client), :environment, environment_id},
      fn -> Fountain.get_environment(client, environment_id) end,
      fn _ -> @environment_ttl_ms end,
      opts
    )
  end

  @doc """
  Fountain's catalog, from the memo for `catalog_ttl_ms/0`. The settings
  panel does not come through here: it validates a harness against the
  catalog as it stands, for the reason `environment/3` gives.
  """
  @spec catalog(Client.t(), opts()) :: {:ok, Shapes.Catalog.t()} | {:error, Fountain.failure()}
  def catalog(%Client{} = client, opts \\ []) do
    memo(
      {client_id(client), :catalog},
      fn -> Fountain.catalog(client) end,
      fn _ -> @catalog_ttl_ms end,
      opts
    )
  end

  @doc "Forget what was derived for one project, on every client."
  @spec forget_project(String.t()) :: :ok
  def forget_project(project_id) do
    Memo.forget_where(@memo, &match?({_client, :conversations, ^project_id, _agent}, &1))
  end

  @doc "Forget one environment, on every client. Called when settings are saved."
  @spec forget_environment(String.t()) :: :ok
  def forget_environment(environment_id) do
    Memo.forget_where(@memo, &match?({_client, :environment, ^environment_id}, &1))
  end

  @doc "For tests: forget everything."
  @spec reset() :: :ok
  def reset, do: Memo.reset(@memo)

  # ── the memo ──────────────────────────────────────────────────────────

  defp memo(key, load, ttl_for, opts) do
    Memo.fetch(@memo, key, load, expires_at(ttl_for), memo_opts(opts))
  end

  # `ttl_for` is handed the loaded value, as it always was. A failure is not
  # remembered at all: the next caller retries rather than being told for
  # five seconds that Fountain is down.
  defp expires_at(ttl_for) do
    fn
      {:ok, value}, started -> started + ttl_for.(value)
      _other, _started -> nil
    end
  end

  # `fresh: true` is "nothing loaded before now", on the caller's clock.
  # Deleting the key instead, as this used to, disowned the load in flight
  # and started another for every caller that arrived during it: a `:turn`
  # on the hub reaches every open page on the project, and each one asked
  # for the same list afresh.
  defp memo_opts(opts) do
    now = Keyword.get_lazy(opts, :now_ms, &Ravix.Clock.now_ms/0)
    fresh = if opts[:fresh], do: [newer_than: now], else: []
    [on_crash: &crashed/1, now_ms: now] ++ fresh
  end

  defp crashed(reason) do
    {:error,
     %Ravix.Fountain.Error{
       status: 0,
       code: "load_crashed",
       message: message(reason),
       kind: :connection
     }}
  end

  defp message(%{__exception__: true} = error), do: Exception.message(error)
  defp message(reason), do: inspect(reason)

  defp list_key(client, project),
    do: {client_id(client), :conversations, project.id, project.agent_id}

  defp client_id(%Client{base_url: base_url}), do: base_url
end
