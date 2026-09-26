defmodule RavixWeb.ToolingOAuthController do
  @moduledoc "OAuth discovery, public-client endpoints and browser consent."
  use RavixWeb, :controller
  plug :no_cache

  alias Ravix.Tooling.OAuth
  alias RavixWeb.{Error, Plugs.CurrentUser}

  defp no_cache(conn, _),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")

  def metadata(conn, _), do: json(conn, OAuth.metadata())

  def resource(conn, %{"resource" => resource}) when resource in ["mcp", "a2a"] do
    json(conn, %{
      resource: OAuth.resource(resource),
      authorization_servers: [Ravix.Config.public_url()],
      scopes_supported: OAuth.scopes(),
      bearer_methods_supported: ["header"]
    })
  end

  def resource(conn, _), do: send_resp(conn, 404, "Not found")

  def register(conn, params), do: oauth_result(conn, OAuth.register(params), 201)
  def token(conn, params), do: oauth_result(conn, OAuth.exchange(params), 200)

  def revoke(conn, params) do
    :ok = OAuth.revoke(params)
    send_resp(conn, 200, "")
  end

  def authorize(conn, params) do
    params = if map_size(params) == 0, do: pending(conn), else: params

    params =
      Map.take(
        params,
        ~w(client_id redirect_uri response_type resource scope state code_challenge_method code_challenge)
      )

    case OAuth.authorization(params) do
      {:ok, request} ->
        nonce = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

        conn =
          put_session(conn, :tooling_authorization, %{
            params: params,
            nonce: nonce,
            at: System.system_time(:second)
          })

        case CurrentUser.require_user(conn) do
          {:ok, _user} ->
            render(conn, :consent,
              request: request,
              nonce: nonce,
              page_title: "Connect an application · Ravix"
            )

          _ ->
            redirect(conn, to: "/auth/github")
        end

      {:error, error} ->
        oauth_result(conn, {:error, error}, 400)
    end
  end

  def consent(conn, params) do
    with {:ok, user} <- CurrentUser.require_user(conn),
         :ok <- matching_consent(conn, params),
         {:ok, url} <- decision(user, pending(conn), params["decision"]) do
      conn |> delete_session(:tooling_authorization) |> redirect(external: url)
    else
      {:error, reason} when is_atom(reason) -> Error.send_json(conn, reason)
      error -> oauth_result(conn, error, 400)
    end
  end

  def disconnect(conn, %{"id" => id}) do
    with {:ok, user} <- CurrentUser.require_user(conn), :ok <- OAuth.disconnect(user, id) do
      redirect(conn, to: "/settings/connections")
    else
      {:error, reason} -> Error.send_json(conn, reason)
    end
  end

  def pending(conn) do
    case get_session(conn, :tooling_authorization) do
      %{params: params, at: at} when is_integer(at) ->
        if System.system_time(:second) - at < 600, do: params, else: %{}

      _ ->
        %{}
    end
  end

  # A second tab must not replace the grant approved on the first tab's page.
  defp matching_consent(conn, params) do
    case get_session(conn, :tooling_authorization) do
      %{nonce: nonce} when is_binary(nonce) ->
        if params["consent_nonce"] == nonce, do: :ok, else: {:error, "invalid_request"}

      _ ->
        {:error, "invalid_request"}
    end
  end

  defp decision(user, params, "allow"), do: OAuth.authorize(user, params)
  defp decision(_user, params, "deny"), do: OAuth.deny(params)
  defp decision(_, _, _), do: {:error, "invalid_request"}

  defp oauth_result(conn, {:ok, result}, status),
    do: conn |> put_resp_header("cache-control", "no-store") |> put_status(status) |> json(result)

  defp oauth_result(conn, {:error, error}, _),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(400)
      |> json(%{error: error})
end
