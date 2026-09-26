defmodule Ravix.Accounts.Inference.Cache do
  @moduledoc """
  Short-lived, per-person credential availability, never credential values.

  Each instance owns its own memo; writes synchronously invalidate the local
  memo and broadcast invalidation to the others. A disconnected instance can
  retain an answer for at most five seconds. Spending decisions bypass it.
  Memo owns the supervised loads and answers invalidated waiters without
  letting their old results overwrite newer reads.
  """
  use GenServer

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
  def invalidate(%User{id: id}), do: GenServer.call(__MODULE__, {:invalidate, id})

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Ravix.PubSub, @topic)
    {:ok, nil}
  end

  @impl true
  def handle_call({:invalidate, id}, _from, state) do
    forget(id)
    Phoenix.PubSub.broadcast_from(Ravix.PubSub, self(), @topic, {:invalidate, id})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:invalidate, id}, state) do
    forget(id)
    {:noreply, state}
  end

  defp forget(id) do
    Memo.forget_where(@memo, fn
      {user_id, _set_id} -> user_id == id
      _forgotten -> false
    end)
  end
end
