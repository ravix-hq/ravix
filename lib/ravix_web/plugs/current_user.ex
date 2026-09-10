defmodule RavixWeb.Plugs.CurrentUser do
  @moduledoc """
  The signed-in user, from the session cookie, into `conn.assigns.current_user`.

  The Phoenix session (a signed cookie) carries the session token under
  `:session_token`; the database holds only its SHA-256, which is what
  `Ravix.Accounts.session_user/1` looks up. A token whose row is gone
  (signed out elsewhere, or expired and swept on this very read) is dropped
  from the session so the next request does not repeat the lookup, and
  `conn.assigns.session_ended` remembers that this request had one, so the
  refusal can say so.

  `current_user` is nil when nobody is signed in. Nothing here refuses: the
  routes that need a person ask `require_user/2` and get the 401 the
  TypeScript's `authenticate` threw.
  """

  import Plug.Conn

  alias Ravix.{Accounts, Crypto}

  @behaviour Plug

  @doc "The session key the token lives under."
  @spec session_key() :: atom()
  def session_key, do: :session_token

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_session(conn, session_key()) do
      token when is_binary(token) and token != "" ->
        case Accounts.session_user(Crypto.sha256(token)) do
          nil ->
            conn
            |> delete_session(session_key())
            |> assign(:current_user, nil)
            |> assign(:session_ended, true)

          user ->
            assign(conn, :current_user, user)
        end

      _ ->
        assign(conn, :current_user, nil)
    end
  end

  @doc "The signed-in user, or the 401 `authenticate` in `server/context.ts` threw."
  @spec require_user(Plug.Conn.t()) ::
          {:ok, Accounts.User.t()} | {:error, :unauthenticated | :session_ended}
  def require_user(conn) do
    case conn.assigns[:current_user] do
      %Accounts.User{} = user ->
        {:ok, user}

      _ ->
        # The cookie named a session that is gone: a different sentence,
        # because "sign in" to somebody who just was is confusing.
        if conn.assigns[:session_ended],
          do: {:error, :session_ended},
          else: {:error, :unauthenticated}
    end
  end
end
