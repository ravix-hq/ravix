defmodule Ravix.GitHub.Cache do
  @moduledoc """
  What the GitHub client remembers between calls.

  Three things, all keyed by the App id so two configured Apps never share:

    * **Installation tokens**, cached until a minute before they expire. A
      minute of slack rather than none because the token is handed to a
      machine that then uses it: a token that was valid when it left here and
      expired in flight fails as `fatal: Authentication failed`, which reads
      like a permissions problem and is not one.
    * **Rate limits**, per installation or user credential. Once GitHub says stop, every read for
      that installation is refused locally until the reset, so twenty mounted
      rows do not each discover the limit for themselves. The limit is GitHub's
      and belongs to the whole deployment rather than to one instance, so it is
      broadcast: without that, each instance would have to earn the same 403 for
      itself, and "twenty rows" would become twenty per instance (ADR 0003).
    * **Checks reports**, for five minutes, including the in-flight read.
      Rows, tabs and viewers asking about the same branch share one request;
      a failed read is remembered for a minute (or until the rate limit
      lifts) so a failure does not turn every mounted row into a retry loop.

  Tokens and rate limits live in a public ETS table on each instance and are
  read and written by the caller. Tokens stay local deliberately: they are
  cheap to mint, GitHub is happy to have several outstanding, and shipping a
  credential between instances to save a request is a bad trade. Checks go through the server, which is the only place that
  can hand one caller the read and park the others until it lands.

  Both processes are started by `Ravix.Application`: this one, which owns the
  token and rate-limit table and listens for its siblings' news, and the
  plain `Ravix.Memo` that holds the checks reports. Neither is started
  lazily. A caller that reaches a cold table is a caller running without the
  application, and a table it quietly conjures for itself is one nothing
  supervises and nothing restarts -- a test that wants the cache should
  start the application, or `start_supervised!/1` the pair it needs.
  """

  use GenServer

  alias Ravix.Clock
  alias Ravix.GitHub.Error
  alias Ravix.Memo

  @table :ravix_github_cache
  @checks Ravix.GitHub.Cache.Checks
  @topic "github:rate_limit"

  @type app_id :: String.t()
  @type installation_id :: integer()
  @type rate_scope :: installation_id() | {:user, binary()}
  @type checks_key :: tuple()
  @type checks_result :: {:ok, term()} | {:error, Error.t()}

  # ── lifecycle ──────────────────────────────────────────────────────

  @doc "Start under a supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── installation tokens ────────────────────────────────────────────

  @doc "The cached token for an installation and when it expires, if any."
  @spec token(app_id(), installation_id()) :: {:ok, String.t(), integer()} | :error
  def token(app_id, installation_id) do
    case :ets.lookup(@table, {:token, app_id, installation_id}) do
      [{_, token, expires_at_ms}] -> {:ok, token, expires_at_ms}
      [] -> :error
    end
  end

  @doc "Remember a freshly minted token."
  @spec put_token(app_id(), installation_id(), String.t(), integer()) :: :ok
  def put_token(app_id, installation_id, token, expires_at_ms) do
    :ets.insert(@table, {{:token, app_id, installation_id}, token, expires_at_ms})
    :ok
  end

  @doc "A non-reversible key for a user's credential; raw tokens never enter cache keys."
  @spec user_scope(String.t()) :: {:user, binary()}
  def user_scope(token), do: {:user, :crypto.hash(:sha256, token)}

  # ── rate limits ────────────────────────────────────────────────────

  @doc "The rate limit GitHub imposed on an installation, if one is remembered."
  @spec rate_limit(app_id(), rate_scope()) :: {:ok, integer(), Error.t()} | :error
  def rate_limit(app_id, installation_id) do
    case :ets.lookup(@table, {:rate_limit, app_id, installation_id}) do
      [{_, until_ms, error}] -> {:ok, until_ms, error}
      [] -> :error
    end
  end

  @doc """
  Refuse reads for this installation until `until_ms`, answering `error`.

  Told to the other instances too. One instance earning a 403 is the whole
  deployment's news: the limit is GitHub's, counted per credential, and an
  instance that has not heard will spend the next reads discovering it again.
  """
  @spec put_rate_limit(app_id(), rate_scope(), integer(), Error.t()) :: :ok
  def put_rate_limit(app_id, installation_id, until_ms, %Error{} = error) do
    put_rate_limit_local(app_id, installation_id, until_ms, error)
    tell_siblings({:rate_limit, app_id, installation_id, until_ms, error})
  end

  @doc "Forget a rate limit (it expired, or a request got through), here and elsewhere."
  @spec clear_rate_limit(app_id(), rate_scope()) :: :ok
  def clear_rate_limit(app_id, installation_id) do
    clear_rate_limit_local(app_id, installation_id)
    tell_siblings({:rate_limit_cleared, app_id, installation_id})
  end

  @doc false
  @spec put_rate_limit_local(app_id(), rate_scope(), integer(), Error.t()) :: :ok
  def put_rate_limit_local(app_id, installation_id, until_ms, %Error{} = error) do
    GenServer.call(__MODULE__, {:remember_limit, app_id, installation_id, until_ms, error})
  end

  @doc false
  @spec clear_rate_limit_local(app_id(), rate_scope()) :: :ok
  def clear_rate_limit_local(app_id, installation_id) do
    :ets.delete(@table, {:rate_limit, app_id, installation_id})
    :ok
  end

  # Best-effort and one-way. A sibling that misses this is not wrong, only
  # uninformed: it will find the limit out the way this instance did. So a
  # PubSub that is not up (a test that never started it) must not fail a
  # GitHub read that has otherwise succeeded.
  defp tell_siblings(message) do
    Phoenix.PubSub.broadcast_from(Ravix.PubSub, self(), @topic, message)
    :ok
  catch
    _kind, _reason -> :ok
  end

  # ── checks ─────────────────────────────────────────────────────────

  @doc """
  The checks report under `key`, reading it with `fun` if nobody has.

  `fun` runs in the calling process (so it sees the caller's `Req.Test`
  stubs); other callers arriving while it runs wait for its answer. `now_ms`
  is the caller's clock, so the tests can move it.
  """
  @spec checks(app_id(), checks_key(), integer(), (-> checks_result())) :: checks_result()
  def checks(app_id, key, now_ms, fun) when is_function(fun, 0) do
    Memo.fetch(@checks, {app_id, key}, fun, &checks_expiry/2,
      now_ms: now_ms,
      run: :caller,
      on_crash: fn _reason -> {:error, crashed()} end
    )
  end

  @doc "Drop every checks report whose key `matches?` (a pull request was opened)."
  @spec drop_checks(app_id(), (checks_key() -> boolean())) :: :ok
  def drop_checks(app_id, matches?) when is_function(matches?, 1) do
    Memo.forget_where(@checks, fn {id, key} -> id == app_id and matches?.(key) end)
  end

  # A report is good for five minutes. A failure is remembered for a minute,
  # or until the rate limit that caused it lifts, whichever is later.
  #
  # Measured from `Clock.now_ms/0` rather than from the moment the load
  # started, which is the second argument and is ignored here on purpose: a
  # rate limit's reset is an absolute time GitHub gave us, and the minute of
  # backoff beside it should be a minute from now.
  defp checks_expiry({:ok, _}, _started), do: Clock.now_ms() + 5 * 60_000

  defp checks_expiry({:error, error}, _started) do
    retry_at =
      case error do
        %Error{retry_at_ms: ms} when is_integer(ms) -> ms
        _ -> 0
      end

    max(Clock.now_ms() + 60_000, retry_at)
  end

  # ── server ─────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Ravix.PubSub, @topic)
    {:ok, %{}}
  end

  # A synchronous round trip, so a caller can be sure every `handle_info/2`
  # queued ahead of it has run. Used by the tests that broadcast a rate limit
  # and then assert this instance took it.
  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :ok, state}

  def handle_call({:remember_limit, app_id, scope, until_ms, error}, _from, state) do
    remember_limit(app_id, scope, until_ms, error)
    {:reply, :ok, state}
  end

  # Replies can arrive out of order, including broadcasts from another node.
  # A shorter cooldown must never shorten one GitHub has already imposed.
  defp remember_limit(app_id, scope, until_ms, error) do
    case rate_limit(app_id, scope) do
      {:ok, existing, _} when existing >= until_ms -> :ok
      _ -> :ets.insert(@table, {{:rate_limit, app_id, scope}, until_ms, error})
    end
  end

  # Another instance met the limit, or got through it. Written straight to this
  # instance's table without being broadcast onward: `broadcast_from/4` already
  # excluded the sender, and re-publishing what we were told is how a message
  # goes round forever.
  @impl true
  def handle_info({:rate_limit, app_id, installation_id, until_ms, error}, state) do
    remember_limit(app_id, installation_id, until_ms, error)
    {:noreply, state}
  end

  def handle_info({:rate_limit_cleared, app_id, installation_id}, state) do
    clear_rate_limit_local(app_id, installation_id)
    {:noreply, state}
  end

  defp crashed, do: %Error{status: nil, message: "The checks read did not complete."}
end
