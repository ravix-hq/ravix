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
      halts: the shell renders the sign-in card for nobody and the workspace
      for somebody, and it is one LiveView, so the choice is the page's.
    * `:require_authenticated_user` does the same, then halts with a
      redirect to `/` when there is nobody. For pages that have nothing to
      show a stranger.

  The token is looked up once per mount through `assign_new/3`, so a
  `live_session` that lists both hooks does not read the database twice.
  """

  import Phoenix.Component, only: [assign_new: 3]
  import Phoenix.LiveView, only: [redirect: 2, attach_hook: 4]

  alias Ravix.{Accounts, Crypto}

  @spec on_mount(
          :fetch_current_user | :require_authenticated_user,
          map(),
          map(),
          Phoenix.LiveView.Socket.t()
        ) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:fetch_current_user, _params, session, socket) do
    {:cont, mount_current_user(session, socket) |> protect_session(session)}
  end

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = mount_current_user(session, socket) |> protect_session(session)

    case socket.assigns[:current_user] do
      %Accounts.User{} -> {:cont, socket}
      _ -> {:halt, redirect(socket, to: "/")}
    end
  end

  # Signing out in another tab revokes this socket on its next event/message.
  defp protect_session(socket, session) do
    token = session["session_token"]
    hash = if is_binary(token), do: Crypto.sha256(token)

    guard = fn s ->
      case hash && Accounts.session_user(hash) do
        %Accounts.User{} -> {:cont, s}
        _ -> {:halt, redirect(s, to: "/login")}
      end
    end

    socket
    |> attach_hook(:session_event, :handle_event, fn _, _, s -> guard.(s) end)
    |> attach_hook(:session_message, :handle_info, fn _, s -> guard.(s) end)
    |> attach_hook(:session_async, :handle_async, fn _, _, s -> guard.(s) end)
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
