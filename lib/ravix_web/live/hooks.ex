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

  import Phoenix.Component, only: [assign: 2, assign_new: 3]
  import Phoenix.LiveView, only: [connected?: 1, redirect: 2, attach_hook: 4]

  alias Ravix.{Accounts, Crypto}
  alias RavixWeb.Live.Guard

  @spec on_mount(
          :fetch_current_user | :require_authenticated_user,
          map(),
          map(),
          Phoenix.LiveView.Socket.t()
        ) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:fetch_current_user, _params, session, socket) do
    {:cont, socket |> mount_session(session) |> protect_session(session)}
  end

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = socket |> mount_session(session) |> protect_session(session)

    case socket.assigns[:current_user] do
      %Accounts.User{} -> {:cont, socket}
      _ -> {:halt, redirect(socket, to: "/")}
    end
  end

  # Signing out in another tab revokes this socket. See `RavixWeb.Live.Guard`
  # for why that no longer means reading the session row on every message:
  # the expiry is a time this page already holds, and the end of a session
  # is announced rather than discovered.
  defp protect_session(socket, session) do
    hash = hash_of(session)
    if connected?(socket) and is_binary(hash), do: Accounts.subscribe_session(hash)

    check = fn s ->
      case Guard.verify(s.assigns[:session_guard], hash) do
        {:ok, guard} -> {:cont, assign(s, session_guard: guard)}
        :error -> {:halt, redirect(s, to: "/login")}
      end
    end

    socket
    |> attach_hook(:session_event, :handle_event, fn _, _, s -> check.(s) end)
    |> attach_hook(:session_message, :handle_info, &session_message(&1, &2, check))
    |> attach_hook(:session_async, :handle_async, fn _, _, s -> check.(s) end)
  end

  # A session's end is this hook's message and no page's: it is halted either
  # way, so no LiveView needs a clause for a message whose only meaning is
  # "you are leaving". Every other message only marks the held answer, and
  # goes on to the page if it still stands.
  defp session_message({:session_ended, _} = message, socket, check) do
    case check.(observed(message, socket)) do
      {:halt, socket} -> {:halt, socket}
      {:cont, socket} -> {:halt, socket}
    end
  end

  defp session_message(message, socket, check), do: check.(observed(message, socket))

  defp observed(message, socket),
    do: assign(socket, session_guard: Guard.observe(message, socket.assigns[:session_guard]))

  # One read of the session at mount, for both the person and the guard that
  # will be asked about them on every message afterwards. `assign_new` keeps
  # a `live_session` listing both hooks from reading it twice.
  defp mount_session(socket, session) do
    hash = hash_of(session)

    socket =
      assign_new(socket, :session_guard, fn ->
        case hash && Accounts.open_session(hash) do
          {:ok, _user, expires_at} -> Guard.new(hash, expires_at)
          _ -> Guard.new(hash, nil)
        end
      end)

    assign_new(socket, :current_user, fn ->
      # The guard above did the read; ask it for the person rather than
      # repeating it. It holds nobody only when there was nobody to hold.
      if Guard.holds?(socket.assigns.session_guard), do: Accounts.session_user(hash)
    end)
  end

  defp hash_of(session) do
    case Map.get(session, "session_token") do
      token when is_binary(token) and token != "" -> Crypto.sha256(token)
      _ -> nil
    end
  end
end
