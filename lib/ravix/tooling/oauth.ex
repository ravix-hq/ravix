defmodule Ravix.Tooling.OAuth do
  @moduledoc "Public-client OAuth with PKCE, resource-bound tokens and revocable rotating grants."
  alias Ravix.Accounts.User
  alias Ravix.{Config, Crypto}
  alias Ravix.Tooling.{Client, Credential, Grant, Store}

  @scopes ~w(projects:read projects:write tracks:read tracks:write tracks:cancel plans:read plans:write)
  def scopes, do: @scopes
  def resource(name) when name in ["mcp", "a2a"], do: Config.public_url() <> "/" <> name

  def metadata do
    base = Config.public_url()

    %{
      issuer: base,
      authorization_endpoint: base <> "/oauth/authorize",
      token_endpoint: base <> "/oauth/token",
      registration_endpoint: base <> "/oauth/register",
      revocation_endpoint: base <> "/oauth/revoke",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      token_endpoint_auth_methods_supported: ["none"],
      code_challenge_methods_supported: ["S256"],
      scopes_supported: scopes()
    }
  end

  def register(%{"client_name" => name, "redirect_uris" => uris} = params)
      when is_binary(name) and is_list(uris) do
    if byte_size(name) in 1..100 and length(uris) in 1..5 and
         Enum.all?(uris, &redirect_uri?/1) and
         params["token_endpoint_auth_method"] in [nil, "none"] do
      row = Store.insert(%Client{id: Ecto.UUID.generate(), name: name, redirect_uris: uris})

      {:ok,
       %{
         client_id: row.id,
         client_name: name,
         redirect_uris: uris,
         token_endpoint_auth_method: "none",
         grant_types: ["authorization_code", "refresh_token"],
         response_types: ["code"]
       }}
    else
      {:error, "invalid_client_metadata"}
    end
  end

  def register(_), do: {:error, "invalid_client_metadata"}

  def authorization(params) when is_map(params) do
    with %Client{} = client <- Store.client(params["client_id"]),
         true <- params["redirect_uri"] in client.redirect_uris,
         true <- params["response_type"] == "code",
         true <- params["resource"] in [resource("mcp"), resource("a2a")],
         true <- params["code_challenge_method"] == "S256",
         true <- challenge?(params["code_challenge"]),
         true <- short_string?(params["state"], 256),
         {:ok, scopes} <- parse_scopes(params["scope"]) do
      {:ok,
       %{
         client: client,
         redirect_uri: params["redirect_uri"],
         resource: params["resource"],
         challenge: params["code_challenge"],
         scopes: scopes,
         state: params["state"]
       }}
    else
      _ -> {:error, "invalid_request"}
    end
  end

  def authorize(%User{} = user, params) do
    with {:ok, request} <- authorization(params) do
      Store.transaction(fn ->
        grant =
          Store.insert(%Grant{
            id: Ecto.UUID.generate(),
            user_id: user.id,
            client_id: request.client.id,
            resource: request.resource,
            scopes: request.scopes,
            expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
          })

        code =
          mint(grant, "code", 300,
            redirect_uri: request.redirect_uri,
            challenge: request.challenge
          )

        redirect(request, %{code: code})
      end)
    end
  end

  def deny(params) do
    with {:ok, request} <- authorization(params),
         do: {:ok, redirect(request, %{error: "access_denied"})}
  end

  def exchange(%{"grant_type" => kind} = params)
      when kind in ["authorization_code", "refresh_token"] do
    token = if kind == "authorization_code", do: params["code"], else: params["refresh_token"]

    with true <- short_string?(token, 256),
         %Credential{} = cred <- Store.credential(Crypto.sha256(token)) do
      Store.transaction(fn -> exchange_locked(cred, kind, params) end)
      |> flatten_exchange()
    else
      _ -> {:error, "invalid_grant"}
    end
  end

  def exchange(_), do: {:error, "unsupported_grant_type"}

  # Lock the grant first, then re-read the credential. All rotations and replay
  # revocations of this family serialize on the same row across app instances.
  defp exchange_locked(cred, kind, params) do
    grant = Store.lock_grant(cred.grant_id)
    current = Store.credential(cred.hash)

    cond do
      not valid_grant?(grant) ->
        {:error, "invalid_grant"}

      grant.client_id != params["client_id"] ->
        {:error, "invalid_grant"}

      grant.resource != params["resource"] ->
        {:error, "invalid_target"}

      not credential_matches?(current, kind, params) ->
        {:error, "invalid_grant"}

      current.used_at != nil ->
        Store.revoke(grant.id)
        {:error, "invalid_grant"}

      expired?(current.expires_at) ->
        {:error, "invalid_grant"}

      true ->
        Store.update(current, used_at: DateTime.utc_now())
        {:ok, tokens(grant)}
    end
  end

  defp flatten_exchange({:ok, result}), do: result
  defp flatten_exchange({:error, _}), do: {:error, "invalid_grant"}

  def authenticate(token, resource) when is_binary(token) and byte_size(token) <= 256 do
    with %Credential{kind: "access", used_at: nil} = cred <-
           Store.credential(Crypto.sha256(token)),
         false <- expired?(cred.expires_at),
         %Grant{resource: ^resource} = grant <- Store.grant(cred.grant_id),
         true <- valid_grant?(grant),
         # ownership: no door before this one -- the credential proves identity;
         # operation contexts subsequently establish project/track access.
         %User{} = user <- Ravix.Accounts.Store.get_user(grant.user_id) do
      :ok = Store.record_use(grant.id)
      {:ok, %{user: user, grant: grant, token: token}}
    else
      _ -> {:error, :unauthenticated}
    end
  end

  def authenticate(_, _), do: {:error, :unauthenticated}

  def check(%{token: token, grant: grant}, scope) do
    with {:ok, principal} <- authenticate(token, grant.resource),
         true <- scope in principal.grant.scopes do
      {:ok, principal}
    else
      false ->
        {:error, {:forbidden, "This connection does not have the required scope: #{scope}."}}

      error ->
        error
    end
  end

  def connections(%User{id: id}) do
    id
    |> Store.grants()
    |> Enum.map(fn g ->
      %{
        id: g.id,
        name: Store.client(g.client_id).name,
        resource: g.resource,
        scopes: g.scopes,
        active: valid_grant?(g),
        connected_at: g.inserted_at,
        last_used_at: g.last_used_at
      }
    end)
  end

  def disconnect(%User{id: user_id}, id) do
    case Store.grant(id) do
      %Grant{user_id: ^user_id} -> Store.revoke(id)
      _ -> {:error, :not_found}
    end
  end

  def revoke(%{"token" => token, "client_id" => client}) when is_binary(token) do
    with %Credential{} = cred <- Store.credential(Crypto.sha256(token)),
         %Grant{client_id: ^client} <- Store.grant(cred.grant_id) do
      Store.revoke(cred.grant_id)
    end

    :ok
  end

  def revoke(_), do: :ok

  defp tokens(grant) do
    %{
      access_token: mint(grant, "access", 3600),
      token_type: "Bearer",
      expires_in: 3600,
      refresh_token: mint(grant, "refresh", 30 * 86_400),
      scope: Enum.join(grant.scopes, " ")
    }
  end

  defp mint(grant, kind, seconds, attrs \\ []) do
    token = Crypto.random_token()

    row =
      struct!(
        Credential,
        [
          hash: Crypto.sha256(token),
          kind: kind,
          grant_id: grant.id,
          expires_at: DateTime.add(DateTime.utc_now(), seconds)
        ] ++ attrs
      )

    Store.insert(row)
    token
  end

  defp credential_matches?(%Credential{kind: "refresh"}, "refresh_token", _), do: true

  defp credential_matches?(%Credential{kind: "code"} = cred, "authorization_code", params) do
    verifier = params["code_verifier"]

    is_binary(verifier) and Regex.match?(~r/^[A-Za-z0-9._~-]{43,128}$/, verifier) and
      cred.redirect_uri == params["redirect_uri"] and
      Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == cred.challenge
  end

  defp credential_matches?(_, _, _), do: false

  defp valid_grant?(%Grant{revoked_at: nil, expires_at: at}), do: not expired?(at)
  defp valid_grant?(_), do: false
  defp expired?(at), do: DateTime.compare(at, DateTime.utc_now()) != :gt
  defp short_string?(s, max), do: is_binary(s) and byte_size(s) in 1..max
  defp challenge?(s), do: is_binary(s) and Regex.match?(~r/^[A-Za-z0-9_-]{43}$/, s)

  defp parse_scopes(s) when is_binary(s) and byte_size(s) <= 256 do
    scopes = String.split(s, " ", trim: true) |> Enum.uniq()
    if scopes != [] and Enum.all?(scopes, &(&1 in @scopes)), do: {:ok, scopes}, else: :error
  end

  defp parse_scopes(_), do: :error

  defp redirect_uri?(s) when is_binary(s) and byte_size(s) <= 512 do
    uri = URI.parse(s)

    uri.userinfo == nil and uri.fragment == nil and is_binary(uri.host) and
      (uri.scheme == "https" or
         (uri.scheme == "http" and uri.host in ["127.0.0.1", "[::1]", "localhost"]))
  end

  defp redirect_uri?(_), do: false

  defp redirect(request, values) do
    uri = URI.parse(request.redirect_uri)

    query =
      URI.decode_query(uri.query || "")
      |> Map.merge(Map.new(values, fn {k, v} -> {to_string(k), v} end))

    URI.to_string(%{uri | query: URI.encode_query(Map.put(query, "state", request.state))})
  end
end
