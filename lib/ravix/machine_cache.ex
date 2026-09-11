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
    - **Refreshed by whoever needs it fresh.** The sidebar's status dot must
      not lag a turn ending, so `Ravix.Tracks.list/2` and `get/2` read live
      and write the result through; everything that only needs the machine's
      identity reads from the memo.

  The sprite behind a sandbox never changes for a given sandbox id, so that
  lookup is memoised for longer; a "not a sprite" answer only briefly, since
  a sandbox mid-provisioning may not have one yet.

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
  alias Ravix.Memo

  @memo __MODULE__
  @ttl_ms 5_000
  @sprite_ttl_ms 60_000

  @typedoc "A conversation as `GET /api/conversations` lists it."
  @type conversation :: Conversation.t()
  @typedoc "Which machine a project is on, or nil when no live conversation names one."
  @type machine :: %{sandbox_id: String.t()} | nil
  @type project :: %{:id => String.t(), :agent_id => String.t(), optional(atom()) => term()}
  @type opts :: [fresh: boolean(), now_ms: integer()]

  @doc "How long a conversation list stands before it is re-read."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc "How long a sandbox's sprite name stands. It does not change."
  @spec sprite_ttl_ms() :: pos_integer()
  def sprite_ttl_ms, do: @sprite_ttl_ms

  @doc false
  def child_spec(opts), do: Memo.child_spec(Keyword.put_new(opts, :name, @memo))

  @doc """
  The project's agent's conversations: from the memo while fresh, unless
  `fresh: true`, in which case Fountain is asked and the memo refreshed.
  Narrowed to the project's agent, never the whole account. A failed read is
  nobody's answer: the next caller retries.
  """
  @spec conversations(Client.t(), project(), opts()) ::
          {:ok, [conversation()]} | {:error, Fountain.failure()}
  def conversations(%Client{} = client, project, opts \\ []) do
    key = list_key(client, project)
    if opts[:fresh], do: forget(key)

    memo(
      key,
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
  @spec machine_of(Client.t(), project(), opts()) ::
          {:ok, machine()} | {:error, Fountain.failure()}
  def machine_of(%Client{} = client, project, opts \\ []) do
    with {:ok, all} <- conversations(client, project, opts) do
      newest =
        all
        |> Enum.filter(&(is_binary(&1.sandbox_id) and Shapes.live?(&1)))
        |> Shapes.newest()

      {:ok, if(newest, do: %{sandbox_id: newest.sandbox_id})}
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

  @doc "Forget what was derived for one project, on every client."
  @spec forget_project(String.t()) :: :ok
  def forget_project(project_id) do
    Memo.forget_where(@memo, &match?({_client, :conversations, ^project_id, _agent}, &1))
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

  defp memo_opts(opts) do
    now = Keyword.take(opts, [:now_ms])
    [on_crash: &crashed/1] ++ now
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

  defp forget(key), do: Memo.forget(@memo, key)

  defp list_key(client, project),
    do: {client_id(client), :conversations, project.id, project.agent_id}

  defp client_id(%Client{base_url: base_url}), do: base_url
end
