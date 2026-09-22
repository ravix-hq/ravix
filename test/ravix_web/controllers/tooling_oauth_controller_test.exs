defmodule RavixWeb.ToolingOAuthControllerTest do
  use RavixWeb.ConnCase, async: true
  alias Ravix.Tooling.OAuth
  import Ravix.ToolingFixture

  test "discovery and registration expose public-client PKCE configuration" do
    metadata =
      build_conn() |> get("/.well-known/oauth-authorization-server") |> json_response(200)

    assert metadata["code_challenge_methods_supported"] == ["S256"]
    assert metadata["token_endpoint_auth_methods_supported"] == ["none"]

    resource =
      build_conn() |> get("/.well-known/oauth-protected-resource/mcp") |> json_response(200)

    assert resource["resource"] == OAuth.resource("mcp")
    assert response(get(build_conn(), "/.well-known/oauth-protected-resource/other"), 404)
    params = %{"client_name" => "Desktop", "redirect_uris" => ["http://127.0.0.1:3456/callback"]}
    assert json_response(post(build_conn(), "/oauth/register", params), 201)["client_id"]
    assert json_response(post(build_conn(), "/oauth/register", %{}), 400)["error"]
  end

  test "consent needs sign-in, shows scopes and redirects only after a POST", %{conn: conn} do
    user = insert_user()
    {params, verifier} = request()
    anonymous = get(conn, "/oauth/authorize", params)
    assert redirected_to(anonymous) == "/auth/github"
    assert get_session(anonymous, :tooling_authorization).params == params
    signed_in = build_conn() |> log_in_user(user) |> get("/oauth/authorize", params)
    body = html_response(signed_in, 200)
    assert body =~ "Allow access"
    assert body =~ "executable setup scripts"
    assert body =~ "127.0.0.1"
    approved = decide(signed_in, "allow")
    location = redirected_to(approved)
    assert location =~ "http://127.0.0.1:8765/callback?"

    code =
      location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("code")

    token_request =
      Map.merge(params, %{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => verifier
      })

    tokens = build_conn() |> post("/oauth/token", token_request) |> json_response(200)
    assert tokens["access_token"]
    assert get_session(approved, :tooling_authorization) == nil

    assert json_response(post(build_conn(), "/oauth/token", token_request), 400)["error"] ==
             "invalid_grant"
  end

  test "denial, stale consent and invalid authorization do not issue credentials", %{conn: conn} do
    {params, _} = request()
    conn = log_in_user(conn, insert_user())

    denied = conn |> get("/oauth/authorize", params) |> decide("deny")

    assert redirected_to(denied) =~ "error=access_denied"
    assert json_response(get(conn, "/oauth/authorize", %{}), 400)["error"] == "invalid_request"

    assert json_response(post(conn, "/oauth/authorize", %{"decision" => "allow"}), 400)["error"] ==
             "invalid_request"

    expired =
      conn
      |> init_test_session(%{tooling_authorization: %{params: params, at: 1}})
      |> get("/oauth/authorize")

    assert json_response(expired, 400)["error"] == "invalid_request"
  end

  test "connected applications page revokes only the caller's grant", %{conn: conn} do
    user = insert_user()
    {p, tokens, params} = principal(user)
    conn = log_in_user(conn, user)
    page = get(conn, "/settings/connections")
    assert html_response(page, 200) =~ "Desktop test"
    assert html_response(page, 200) =~ "Disconnect"

    assert redirected_to(post(conn, "/settings/connections/#{p.grant.id}/revoke")) ==
             "/settings/connections"

    assert {:error, :unauthenticated} =
             OAuth.authenticate(tokens.access_token, params["resource"])

    assert json_response(post(conn, "/settings/connections/unknown/revoke"), 404)
    assert redirected_to(get(build_conn(), "/settings/connections")) == "/auth/github"

    assert response(
             post(build_conn(), "/oauth/revoke", %{"token" => "unknown", "client_id" => "unknown"}),
             200
           ) == ""
  end

  test "an older consent page cannot approve a request opened in another tab" do
    {first, _} = request()
    {second, _} = request()
    conn = build_conn() |> log_in_user(insert_user()) |> get("/oauth/authorize", first)
    old_nonce = get_session(conn, :tooling_authorization).nonce
    conn = conn |> recycle() |> get("/oauth/authorize", second)

    refused =
      conn
      |> recycle()
      |> post("/oauth/authorize", %{"decision" => "allow", "consent_nonce" => old_nonce})

    assert json_response(refused, 400)["error"] == "invalid_request"
    assert redirected_to(decide(conn, "allow")) =~ "code="
  end

  defp decide(conn, decision) do
    nonce = get_session(conn, :tooling_authorization).nonce

    conn
    |> recycle()
    |> post("/oauth/authorize", %{"decision" => decision, "consent_nonce" => nonce})
  end
end
