defmodule RavixWeb.WorkspaceGuardFixtureLive do
  @moduledoc """
  The smallest page that holds a workspace, for `RavixWeb.Live.WorkspaceGuard`'s
  tests. No real page holds one until phase 4's selector; this stands in for
  it, mounted at `RavixWeb.WorkspaceGuardFixture.Router` because the guard
  hooks `handle_params/3`, which LiveView allows only on a routed page.

  `"load"` starts an async read whose answer the test releases, so a test
  can revoke the membership while it is in flight. `"ping"` is an event and
  `:ping` a message; each counts, so a test can see whether it got through.
  `?tab=` is a URL a test can patch to.
  """
  use RavixWeb, :live_view

  alias RavixWeb.Live.WorkspaceGuard

  on_mount {RavixWeb.Live.Hooks, :require_authenticated_user}

  @impl true
  def mount(%{"workspace_id" => id}, %{"test" => test}, socket) do
    socket = assign(socket, test: test, loaded: nil, pings: 0, tab: nil)

    case WorkspaceGuard.hold(socket, id) do
      {:ok, socket} -> {:ok, socket}
      {:error, :not_found} -> {:ok, redirect(socket, to: "/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, assign(socket, tab: params["tab"])}

  @impl true
  def render(assigns) do
    ~H"""
    <p id="role">{@workspace_access.role}</p>
    <p id="pings">{@pings}</p>
    <p id="loaded">{@loaded}</p>
    <p id="tab">{@tab}</p>
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

defmodule RavixWeb.WorkspaceGuardFixture.Router do
  @moduledoc "Routes the fixture page, and nothing else. Test-only."
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :fetch_session
  end

  scope "/" do
    pipe_through :browser
    live "/workspaces/:workspace_id", RavixWeb.WorkspaceGuardFixtureLive
  end
end

defmodule RavixWeb.WorkspaceGuardFixture.Endpoint do
  @moduledoc """
  An endpoint for the fixture router, so the production router carries no
  test routes. Started per test module with `start_supervised!/1`; its
  configuration is put by `put_config/0` first.
  """
  use Phoenix.Endpoint, otp_app: :ravix

  plug Plug.Session, store: :cookie, key: "_fixture", signing_salt: "wsguard1"
  plug RavixWeb.WorkspaceGuardFixture.Router

  @doc "Put this endpoint's configuration, borrowing the real endpoint's secret."
  @spec put_config() :: :ok
  def put_config do
    Application.put_env(:ravix, __MODULE__,
      secret_key_base: RavixWeb.Endpoint.config(:secret_key_base),
      live_view: [signing_salt: "wsguard-live"],
      pubsub_server: Ravix.PubSub,
      server: false
    )
  end
end
