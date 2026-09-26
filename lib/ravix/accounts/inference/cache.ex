defmodule Ravix.Accounts.Inference.Cache do
  @moduledoc """
  Short-lived, per-person credential availability, never credential values.

  Each instance owns its own memo; writes synchronously invalidate the local
  memo directly in the caller and broadcast invalidation to every subscriber.
  The subscriber is only a listener, never on the credential write path. Cache
  outages are logged and do not change a write result. A disconnected instance can
  retain an answer for at most five seconds. Spending decisions bypass it.
  Memo owns the supervised loads and answers invalidated waiters without
  letting their old results overwrite newer reads.
  """
  use GenServer

  require Logger

  alias Ravix.Accounts.User
  alias Ravix.Memo

  @memo __MODULE__.Reads
  @topic "inference:credentials"
  @ttl_ms 5_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def fetch(%User{id: id, credential_set_id: set_id}, load) do
    Memo.fetch(@memo, {id, set_id}, load, fn
      {:ok, _}, started -> started + @ttl_ms
      {:error, _}, _started -> nil
    end)
  end

  @doc false
  def invalidate(%User{id: id}) do
    forget(id)
    best_effort(fn -> Phoenix.PubSub.broadcast(Ravix.PubSub, @topic, {:invalidate, id}) end)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Ravix.PubSub, @topic)
    {:ok, nil}
  end

  @impl true
  def handle_info({:invalidate, id}, state) do
    forget(id)
    {:noreply, state}
  end

  defp forget(id) do
    best_effort(fn ->
      Memo.forget_where(@memo, fn
        {user_id, _set_id} -> user_id == id
        _forgotten -> false
      end)
    end)
  end

  # Cache availability must never change the outcome of a credential write.
  # The memo may be restarting (missing table / process) or its call may time
  # out. Broadcast still gets a chance to invalidate surviving subscribers.
  defp best_effort(fun) do
    fun.()
    :ok
  rescue
    ArgumentError -> invalidation_failed()
  catch
    :exit, _reason -> invalidation_failed()
  end

  defp invalidation_failed do
    Logger.warning(
      "Inference cache invalidation unavailable; cached reads expire within five seconds"
    )

    :ok
  end
end
