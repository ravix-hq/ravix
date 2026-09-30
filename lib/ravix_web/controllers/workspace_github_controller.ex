defmodule RavixWeb.WorkspaceGitHubController do
  @moduledoc """
  The HTTP half of connecting GitHub to a workspace (ADR 0009, phase 4b).

      GET /w/:workspace/github/connect   mint the round trip; redirect to GitHub

  GitHub comes back to the App's setup URL, `/api/auth/callback`, which
  `RavixWeb.AuthController.callback/2` hands here (`finish/2`) when the
  state is a connect state. Both need the browser's own session: the round
  trip is bound to it (see `Ravix.Workspaces.Connect`). Every answer is a
  redirect, because a browser following GitHub opens these, not a fetch.
  """
  use RavixWeb, :controller

  alias Ravix.Crypto
  alias Ravix.Workspaces.Connect
  alias RavixWeb.Error
  alias RavixWeb.Plugs.CurrentUser

  @doc "`GET /w/:workspace/github/connect`: to GitHub's install/configure page."
  @spec connect(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def connect(conn, %{"workspace" => workspace_id}) do
    with {:ok, user} <- CurrentUser.require_user(conn),
         {:ok, url} <- Connect.begin(user, workspace_id, session_hash(conn)) do
      redirect(conn, external: url)
    else
      {:error, reason} -> Error.send_json(conn, reason)
    end
  end

  @doc """
  GitHub back from a connect round trip, as `/api/auth/callback` received
  it. Lands on the workspace page, saying what happened; a state that does
  not finish lands there too when it names a workspace, and home otherwise.
  """
  @spec finish(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def finish(conn, params) do
    state = params["state"]
    back = Connect.workspace_of(state)

    result =
      with {:ok, user} <- CurrentUser.require_user(conn) do
        Connect.finish(
          user,
          session_hash(conn),
          state,
          params["installation_id"],
          params["code"]
        )
      end

    case result do
      {:ok, workspace_id} ->
        redirect(conn, to: "/w/#{workspace_id}/settings/repositories?github=connected")

      {:error, reason} when is_binary(back) ->
        redirect(conn, to: "/w/#{back}/settings/repositories?github_error=#{code(reason)}")

      {:error, reason} ->
        redirect(conn, to: "/?error=#{code(reason)}")
    end
  end

  defp code(:stale), do: "stale_connect"
  defp code(reason), do: Error.from(reason).code

  defp session_hash(conn) do
    case get_session(conn, CurrentUser.session_key()) do
      token when is_binary(token) and token != "" -> Crypto.sha256(token)
      _ -> nil
    end
  end
end
