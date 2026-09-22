defmodule Ravix.ToolingFixture do
  @moduledoc "Real OAuth grants through registration, consent and PKCE exchange."
  alias Ravix.Tooling.OAuth

  def request(resource \\ "mcp", scopes \\ OAuth.scopes()) do
    {:ok, client} =
      OAuth.register(%{
        "client_name" => "Desktop test",
        "redirect_uris" => ["http://127.0.0.1:8765/callback"]
      })

    verifier = String.duplicate("v", 43)

    params = %{
      "client_id" => client.client_id,
      "redirect_uri" => hd(client.redirect_uris),
      "response_type" => "code",
      "resource" => OAuth.resource(resource),
      "scope" => Enum.join(scopes, " "),
      "state" => "test-state",
      "code_challenge_method" => "S256",
      "code_challenge" => Ravix.Crypto.sha256(verifier)
    }

    {params, verifier}
  end

  def principal(user, resource \\ "mcp", scopes \\ OAuth.scopes()) do
    {params, verifier} = request(resource, scopes)
    {:ok, url} = OAuth.authorize(user, params)
    code = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("code")

    exchange =
      Map.merge(params, %{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => verifier
      })

    {:ok, tokens} = OAuth.exchange(exchange)
    {:ok, principal} = OAuth.authenticate(tokens.access_token, params["resource"])
    {principal, tokens, params}
  end
end
