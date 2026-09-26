defmodule Ravix.Tooling.OAuthTest do
  use Ravix.DataCase, async: true
  alias Ravix.Tooling.{Credential, Grant, OAuth}
  import Ravix.ToolingFixture

  test "connection activity records valid token use without changing the connection date" do
    user = insert_user()
    {principal, tokens, params} = principal(user)
    grant = Repo.get!(Grant, principal.grant.id)
    Repo.update!(Ecto.Changeset.change(grant, last_used_at: nil))
    assert [%{connected_at: connected, last_used_at: nil}] = OAuth.connections(user)
    assert connected == grant.inserted_at

    assert {:error, :unauthenticated} =
             OAuth.authenticate(tokens.access_token, OAuth.resource("a2a"))

    assert {:error, :unauthenticated} =
             OAuth.authenticate(tokens.refresh_token, params["resource"])

    assert [%{last_used_at: nil}] = OAuth.connections(user)

    before_use = DateTime.utc_now()
    assert {:ok, _} = OAuth.authenticate(tokens.access_token, params["resource"])
    assert [%{last_used_at: used, connected_at: ^connected}] = OAuth.connections(user)
    assert DateTime.compare(used, before_use) in [:eq, :gt]
    assert {:ok, _} = OAuth.authenticate(tokens.access_token, params["resource"])
    assert [%{last_used_at: ^used}] = OAuth.connections(user)

    old = DateTime.add(used, -120, :second)
    Repo.update!(Ecto.Changeset.change(Repo.get!(Grant, grant.id), last_used_at: old))
    assert {:ok, _} = OAuth.authenticate(tokens.access_token, params["resource"])
    assert [%{last_used_at: updated}] = OAuth.connections(user)
    assert DateTime.compare(updated, old) == :gt
    assert :ok = OAuth.disconnect(user, grant.id)

    assert {:error, :unauthenticated} =
             OAuth.authenticate(tokens.access_token, params["resource"])

    assert [%{last_used_at: ^updated, active: false}] = OAuth.connections(user)
    assert OAuth.connections(insert_user()) == []
  end

  test "PKCE exchange binds tokens to their resource, user and scopes" do
    user = insert_user()
    {p, tokens, _} = principal(user, "mcp", ["tracks:read"])
    assert p.user.id == user.id
    assert {:ok, _} = OAuth.check(p, "tracks:read")
    assert {:error, {:forbidden, _}} = OAuth.check(p, "tracks:write")

    assert {:error, :unauthenticated} =
             OAuth.authenticate(tokens.access_token, OAuth.resource("a2a"))

    assert {:error, :unauthenticated} =
             OAuth.authenticate(tokens.refresh_token, OAuth.resource("mcp"))

    assert {:error, :unauthenticated} = OAuth.authenticate(nil, OAuth.resource("mcp"))
    assert {:error, :unauthenticated} = OAuth.authenticate("unknown", OAuth.resource("mcp"))
    refute Repo.get(Credential, tokens.access_token)
    assert [%{active: true, name: "Desktop test"}] = OAuth.connections(user)
    assert {:error, :not_found} = OAuth.disconnect(insert_user(), p.grant.id)
    assert :ok = OAuth.disconnect(user, p.grant.id)
    assert {:error, :unauthenticated} = OAuth.check(p, "tracks:read")
    assert [%{active: false}] = OAuth.connections(user)
  end

  test "refresh rotates once, and replay revokes the entire token family" do
    {p, tokens, params} = principal(insert_user())

    refresh = %{
      "grant_type" => "refresh_token",
      "refresh_token" => tokens.refresh_token,
      "client_id" => params["client_id"],
      "resource" => params["resource"]
    }

    assert {:error, "invalid_target"} =
             OAuth.exchange(%{refresh | "resource" => OAuth.resource("a2a")})

    assert {:error, "invalid_grant"} = OAuth.exchange(%{refresh | "client_id" => "other"})
    assert {:ok, next} = OAuth.exchange(refresh)
    refute tokens.refresh_token == next.refresh_token
    assert {:ok, _} = OAuth.authenticate(next.access_token, params["resource"])
    assert {:error, "invalid_grant"} = OAuth.exchange(refresh)
    assert {:error, :unauthenticated} = OAuth.authenticate(next.access_token, params["resource"])
    assert {:error, :unauthenticated} = OAuth.check(p, "tracks:read")
  end

  test "authorization codes require the registered redirect and correct verifier and are single-use" do
    user = insert_user()
    {params, verifier} = request()
    assert {:ok, url} = OAuth.authorize(user, params)
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["state"] == params["state"]

    args =
      Map.merge(params, %{
        "grant_type" => "authorization_code",
        "code" => query["code"],
        "code_verifier" => verifier
      })

    assert {:error, "invalid_grant"} =
             OAuth.exchange(%{args | "code_verifier" => String.duplicate("x", 43)})

    assert {:error, "invalid_grant"} =
             OAuth.exchange(%{args | "redirect_uri" => "http://127.0.0.1:9999/callback"})

    assert {:ok, tokens} = OAuth.exchange(args)
    assert {:error, "invalid_grant"} = OAuth.exchange(args)

    assert {:error, :unauthenticated} =
             OAuth.authenticate(tokens.access_token, params["resource"])

    assert {:ok, denied} = OAuth.deny(params)
    assert denied =~ "error=access_denied"
    assert {:error, "unsupported_grant_type"} = OAuth.exchange(%{})

    assert {:error, "invalid_grant"} =
             OAuth.exchange(%{"grant_type" => "authorization_code", "code" => []})
  end

  test "registration and authorization reject malformed, unsafe and unregistered inputs" do
    for redirect <- [
          "http://attacker.test/callback",
          "javascript:alert(1)",
          "https://user:pass@example.com/cb",
          "https://example.com/cb#fragment",
          7
        ] do
      assert {:error, _} =
               OAuth.register(%{"client_name" => "test", "redirect_uris" => [redirect]})
    end

    assert {:error, _} = OAuth.register(%{})
    assert {:error, _} = OAuth.register(%{"client_name" => "test", "redirect_uris" => []})

    assert {:ok, _} =
             OAuth.register(%{
               "client_name" => "test",
               "redirect_uris" => ["https://desktop.test/callback"]
             })

    {params, _} = request()

    for {key, value} <- [
          {"client_id", nil},
          {"redirect_uri", "https://evil.test"},
          {"response_type", "token"},
          {"resource", "https://evil.test/mcp"},
          {"code_challenge_method", "plain"},
          {"code_challenge", "bad"},
          {"scope", "admin"},
          {"scope", ""},
          {"scope", []},
          {"state", nil}
        ] do
      assert {:error, _} = OAuth.authorization(Map.put(params, key, value))
    end
  end

  test "expired credentials and grants fail, revocation is idempotent without disclosing token existence" do
    user = insert_user()
    {p, tokens, params} = principal(user)
    cred = Repo.get!(Credential, Ravix.Crypto.sha256(tokens.access_token))
    cred |> change(expires_at: DateTime.add(DateTime.utc_now(), -1)) |> Repo.update!()

    assert {:error, :unauthenticated} =
             OAuth.authenticate(tokens.access_token, params["resource"])

    assert :ok = OAuth.revoke(%{"token" => tokens.refresh_token, "client_id" => "another"})
    refute Repo.get!(Grant, p.grant.id).revoked_at

    assert :ok =
             OAuth.revoke(%{"token" => tokens.refresh_token, "client_id" => params["client_id"]})

    assert Repo.get!(Grant, p.grant.id).revoked_at
    assert :ok = OAuth.revoke(%{})
    assert :ok = OAuth.revoke(%{"token" => "missing", "client_id" => "missing"})

    {p, tokens, params} = principal(user)
    p.grant |> change(expires_at: DateTime.add(DateTime.utc_now(), -1)) |> Repo.update!()

    assert {:error, :unauthenticated} =
             OAuth.authenticate(tokens.access_token, params["resource"])
  end
end
