defmodule RavixWeb.WorkspaceGuardFixtureLive do
  @moduledoc """
  The smallest page that holds a workspace, for `RavixWeb.Live.WorkspaceGuard`'s
  tests. No real page holds one until phase 4's selector; this stands in for
  it through `live_isolated/3`.

  `"load"` starts an async read whose answer the test releases, so a test
  can revoke the membership while it is in flight. `"ping"` is an event and
  `:ping` a message; each counts, so a test can see whether it got through.
  """
  use RavixWeb, :live_view

  alias RavixWeb.Live.WorkspaceGuard

  on_mount {RavixWeb.Live.Hooks, :require_authenticated_user}

  @impl true
  def mount(_params, %{"workspace_id" => id, "test" => test}, socket) do
    socket = assign(socket, test: test, loaded: nil, pings: 0)

    case WorkspaceGuard.hold(socket, id) do
      {:ok, socket} -> {:ok, socket}
      {:error, :not_found} -> {:ok, redirect(socket, to: "/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <p id="role">{@workspace_access.role}</p>
    <p id="pings">{@pings}</p>
    <p id="loaded">{@loaded}</p>
    """
  end

  @impl true
  def handle_event("ping", _params, socket), do: {:noreply, update(socket, :pings, &(&1 + 1))}

  def handle_event("load", _params, socket) do
    test = socket.assigns.test

    {:noreply,
     start_async(socket, :load, fn ->
       send(test, {:loading, self()})

       receive do
         {:release, value} -> value
       end
     end)}
  end

  @impl true
  def handle_info(:ping, socket), do: {:noreply, update(socket, :pings, &(&1 + 1))}

  @impl true
  def handle_async(:load, {:ok, value}, socket), do: {:noreply, assign(socket, loaded: value)}
end
