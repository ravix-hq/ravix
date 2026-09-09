defmodule RavixWeb.Live.Hooks do
  @moduledoc """
  LiveView `on_mount` hooks: who is on the socket.

  ## Usage in the router

      live_session :workspace,
        on_mount: [{RavixWeb.Live.Hooks, :fetch_current_user}] do
        live "/", WorkspaceLive, :home
      end

  ## Hooks

    * `:fetch_current_user` assigns `:current_user` (a `%Ravix.Accounts.User{}`
      or nil) from the `session_token` the Phoenix session carries, the same
      way `RavixWeb.Plugs.CurrentUser` does for a plain request. Never
      halts: the shell renders the landing page for nobody and the workspace
      for somebody, and it is one LiveView, so the choice is the page's.
    * `:require_authenticated_user` does the same, then halts with a
      redirect to `/` when there is nobody. For pages that have nothing to
      show a stranger.

  The token is looked up once per mount through `assign_new/3`, so a
  `live_session` that lists both hooks does not read the database twice.
  """

  import Phoenix.Component, only: [assign_new: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias Ravix.{Accounts, Crypto}

  @spec on_mount(
          :fetch_current_user | :require_authenticated_user,
          map(),
          map(),
          Phoenix.LiveView.Socket.t()
        ) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:fetch_current_user, _params, session, socket) do
    {:cont, mount_current_user(session, socket)}
  end

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = mount_current_user(session, socket)

    case socket.assigns[:current_user] do
      %Accounts.User{} -> {:cont, socket}
      _ -> {:halt, redirect(socket, to: "/")}
    end
  end

  # Mount current_user from the session into socket assigns without hitting
  # the database a second time if a previous hook already did.
  defp mount_current_user(session, socket) do
    assign_new(socket, :current_user, fn ->
      case Map.get(session, "session_token") do
        token when is_binary(token) and token != "" -> Accounts.session_user(Crypto.sha256(token))
        _ -> nil
      end
    end)
  end
end
