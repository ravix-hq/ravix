defmodule RavixWeb.ConnCase do
  @moduledoc """
  The test case for anything that goes through the endpoint: controllers
  and LiveView pages.

  Brings `Phoenix.ConnTest`, the factory, and two helpers for being signed
  in. `log_in_user/2` puts a real session token into the Phoenix session,
  the way `RavixWeb.AuthController.callback/2` does after GitHub comes back,
  so the request runs through `RavixWeb.Plugs.CurrentUser` and the LiveView
  hooks exactly as a browser's would. The SQL sandbox is started per test,
  so `async: true` is fine on Postgres.
  """

  use ExUnit.CaseTemplate

  alias Ravix.Accounts.User
  alias Ravix.Factory
  alias RavixWeb.Plugs.CurrentUser

  using do
    quote do
      # The default endpoint for testing
      @endpoint RavixWeb.Endpoint

      use RavixWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Ravix.Factory
      import RavixWeb.ConnCase
    end
  end

  setup tags do
    Ravix.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  A signed-in `conn` for `user`: a fresh session row, with its token in the
  Phoenix session under `:session_token`. Returns the conn; the token is
  readable back with `get_session(conn, :session_token)`.
  """
  @spec log_in_user(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def log_in_user(conn, %User{} = user) do
    {token, _session} = Factory.insert_session(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(CurrentUser.session_key(), token)
  end

  @doc """
  A new user with a stored GitHub token, signed in. For a `setup`:

      setup :register_and_log_in_user

  Adds `:user` to the context and replaces `:conn` with the signed-in one.
  """
  @spec register_and_log_in_user(%{required(:conn) => Plug.Conn.t(), optional(any()) => any()}) ::
          %{conn: Plug.Conn.t(), user: Ravix.Accounts.User.t()}
  def register_and_log_in_user(%{conn: conn}) do
    user =
      Ravix.Factory.insert_user(token_enc: Ravix.Crypto.encrypt("gho_test_" <> user_suffix()))

    %{conn: log_in_user(conn, user), user: user}
  end

  defp user_suffix, do: Integer.to_string(System.unique_integer([:positive]))
end
