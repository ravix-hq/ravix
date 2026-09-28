defmodule Ravix.GitHubFake do
  @moduledoc """
  GitHub, stood in for by `Req.Test`.

  `Ravix.GitHub` merges `Application.get_env(:ravix, :req_options)` into every
  request, and `config/test.exs` points that at the `Ravix.ReqFake` stub.
  `install/1` registers that stub for the calling test and routes each request
  to the first matching `{method, path, handler}` route. Stubs are per-process, so async tests never see each other's
  GitHub, and the stub name is shared with the other Req clients for the
  same reason: whichever client a test exercises, its requests land here.

  Every request is also reported to the test process as
  `{Ravix.GitHubFake, method, path}`, so a test can count them.

  One rule holds before any route is consulted, because GitHub holds it: an
  App JWT is refused with 401 "Bad credentials" anywhere outside `/app/...`.
  A mock that accepted any token let `user_by_login/2` ship sending the JWT
  to `/users/:login`, and every invite by login failed in production.
  """

  alias Ravix.Accounts.Store, as: Accounts
  alias Ravix.Config.GitHubApp

  @stub Ravix.ReqFake

  @type handler ::
          (Plug.Conn.t() -> Plug.Conn.t())
          | {non_neg_integer(), term()}
          | {non_neg_integer(), [{String.t(), String.t()}], term()}
          | term()
  @type route :: {String.t(), String.t() | Regex.t(), handler()}

  @doc "The stub name every Req client in the test suite routes through."
  @spec stub_name() :: atom()
  def stub_name, do: @stub

  @doc "A complete App pointed at the fake, with a fresh App id so caches never collide."
  @spec app(keyword()) :: GitHubApp.t()
  def app(overrides \\ []) do
    struct!(
      %GitHubApp{
        app_id: "app-#{System.unique_integer([:positive])}",
        slug: "test",
        client_id: "Iv1.x",
        client_secret: "s",
        private_key_pem: private_key_pem(),
        api_url: "https://api.github.test",
        web_url: "https://github.test"
      },
      overrides
    )
  end

  @doc "Route this test's GitHub requests to `routes`, in order; anything else fails the test."
  @spec install([route()]) :: :ok
  def install(routes) do
    owner = self()

    Req.Test.stub(@stub, fn conn ->
      send(owner, {__MODULE__, conn.method, conn.request_path})

      if app_jwt_outside_app?(conn),
        do: respond(conn, {401, %{message: "Bad credentials"}}),
        else: respond(conn, find_route(routes, conn))
    end)
  end

  defp app_jwt_outside_app?(conn) do
    not String.starts_with?(conn.request_path, "/app/") and
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> app_jwt?(token)
        _ -> false
      end
  end

  # A JWT this fake's App key signed. Installation and user tokens in the
  # suite are plain strings, so the shape check spares them the verify.
  defp app_jwt?(token) do
    length(String.split(token, ".")) == 3 and
      try do
        is_map(verify_app_jwt!(token))
      rescue
        _ -> false
      end
  end

  defp find_route(routes, %Plug.Conn{method: method, request_path: path} = conn) do
    case Enum.find(routes, fn {m, p, _} -> m == method and path_matches?(p, path) end) do
      {_, _, handler} -> handler
      nil -> raise "Ravix.GitHubFake: no route for #{method} #{path}?#{conn.query_string}"
    end
  end

  @doc "How many requests this test's GitHub has seen, optionally only those whose path contains `fragment`."
  @spec request_count(String.t() | nil) :: non_neg_integer()
  def request_count(fragment \\ nil) do
    requests()
    |> Enum.count(fn {_m, path} -> is_nil(fragment) or String.contains?(path, fragment) end)
  end

  @doc "Every `{method, path}` this test's GitHub has seen, oldest first (drains the mailbox)."
  @spec requests() :: [{String.t(), String.t()}]
  def requests, do: drain([])

  @doc """
  The token endpoint: mints `token-1`, `token-2`, ... on each call, after
  checking the App JWT the way GitHub would (RS256 by the App's public key,
  `iss` naming the App).

  With no App, any App the fake's key signed for is accepted: for suites
  that stub `Ravix.Config.github/0` with a fresh `app/0` on every call.
  """
  @spec token_route(GitHubApp.t() | nil) :: route()
  def token_route(app \\ nil) do
    counter = :counters.new(1, [])

    {"POST", ~r{^/app/installations/\d+/access_tokens$},
     fn conn ->
       claims = app_claims!(conn)

       if app && claims["iss"] != app.app_id,
         do: raise("App JWT names #{inspect(claims["iss"])}, not #{inspect(app.app_id)}")

       :counters.add(counter, 1, 1)
       n = :counters.get(counter, 1)
       expires = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
       Req.Test.json(conn, %{token: "token-#{n}", expires_at: expires})
     end}
  end

  @doc """
  `GET /app/installations`, listed as the App: one installation per id, in
  order. What `Ravix.GitHub` reads to find any installation to make the
  App's own reads outside `/app/...` with.
  """
  @spec installations_route([integer()]) :: route()
  def installations_route(ids \\ [1]) do
    {"GET", "/app/installations",
     fn conn ->
       app_claims!(conn)
       Req.Test.json(conn, Enum.map(ids, &%{id: &1, account: %{login: "org-#{&1}"}}))
     end}
  end

  @doc """
  The routes a read on the App's behalf needs before the read itself: its
  installations (`ids`) and a token for them. See `installations_route/1`.
  """
  @spec app_reader_routes([integer()]) :: [route()]
  def app_reader_routes(ids \\ [1]), do: [installations_route(ids), token_route()]

  defp app_claims!(conn) do
    ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
    verify_app_jwt!(jwt)
  end

  @doc "The claims of an App JWT this fake's key signed; raises when the signature is bad."
  @spec verify_app_jwt!(String.t()) :: map()
  def verify_app_jwt!(jwt) do
    public = private_key_pem() |> JOSE.JWK.from_pem() |> JOSE.JWK.to_public()

    case JOSE.JWT.verify_strict(public, ["RS256"], jwt) do
      {true, %JOSE.JWT{fields: claims}, _} -> claims
      {false, _, _} -> raise "App JWT signature did not verify"
    end
  end

  @doc """
  A PKCS#1 PEM (`BEGIN RSA PRIVATE KEY`), as GitHub issues them. Generated once
  per run, and once means once.

  The generation is behind a lock because the check and the store are not one
  step. Several async suites call this within milliseconds of the run starting
  -- `app/0` is in the setup of four of them -- and RSA-2048 keygen is slow
  enough that they all saw an empty `:persistent_term`, all generated a
  different key, and all stored it. Each caller kept *its own* key in the
  `%GitHubApp{}` it built, while `verify_app_jwt!/1` reads whatever the last
  writer stored: every test but one was then holding a key the fake would not
  verify with. It surfaced as `App JWT signature did not verify` in whichever
  test lost, a long way from here, and only under the scheduling of a machine
  with fewer cores than a developer's.
  """
  @spec private_key_pem() :: String.t()
  def private_key_pem do
    case :persistent_term.get({__MODULE__, :pem}, nil) do
      nil -> generate_key_once()
      pem -> pem
    end
  end

  # Re-checked inside the lock: the caller that waited for it must take the key
  # the winner stored rather than generate a second one.
  defp generate_key_once do
    :global.trans({{__MODULE__, :pem}, self()}, fn ->
      case :persistent_term.get({__MODULE__, :pem}, nil) do
        nil ->
          key = :public_key.generate_key({:rsa, 2048, 65_537})
          pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
          :persistent_term.put({__MODULE__, :pem}, pem)
          pem

        pem ->
          pem
      end
    end)
  end

  @doc "The public half of `private_key_pem/0`: a well-formed PEM that cannot sign."
  @spec public_key_pem() :: String.t()
  def public_key_pem do
    {_, pem} =
      private_key_pem() |> JOSE.JWK.from_pem() |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()

    pem
  end

  @doc "The same key as PKCS#8 (`BEGIN PRIVATE KEY`), the other shape GitHub accepts."
  @spec private_key_pem_pkcs8() :: String.t()
  def private_key_pem_pkcs8 do
    {_, pem} = private_key_pem() |> JOSE.JWK.from_pem() |> JOSE.JWK.to_pem()
    pem
  end

  # ── plumbing ───────────────────────────────────────────────────────

  defp path_matches?(%Regex{} = re, path), do: Regex.match?(re, path)
  defp path_matches?(exact, path) when is_binary(exact), do: exact == path

  @doc """
  A `GET /users/:login` route: GitHub's current answer for a login.

  `accounts` maps a lowercased login to `{github_id, login}` for accounts
  GitHub knows that are not, or are no longer, the local user of that login
  (a rename, somebody who never signed in here). Anything else is the local
  user holding the login, and otherwise 404.
  """
  @spec users_route(%{String.t() => {String.t() | integer(), String.t()}}) :: route()
  def users_route(accounts \\ %{}) do
    {"GET", ~r{^/users/[^/]+$},
     fn conn ->
       login = conn.request_path |> String.split("/") |> List.last()

       case Map.get(accounts, String.downcase(login)) ||
              local(Accounts.user_by_login(login)) do
         {id, name} ->
           Req.Test.json(conn, %{id: id, login: name, avatar_url: "https://a/#{id}"})

         nil ->
           conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{message: "Not Found"})
       end
     end}
  end

  defp local(nil), do: nil
  defp local(user), do: {String.to_integer(user.github_id), user.login}

  defp respond(conn, fun) when is_function(fun, 1), do: fun.(conn)

  defp respond(conn, {status, headers, body}) when is_integer(status) and is_list(headers) do
    headers
    |> Enum.reduce(conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
    |> Plug.Conn.put_status(status)
    |> Req.Test.json(body)
  end

  defp respond(conn, {status, body}) when is_integer(status) do
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
  end

  defp respond(conn, body), do: Req.Test.json(conn, body)

  defp drain(acc) do
    receive do
      {__MODULE__, method, path} -> drain([{method, path} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
