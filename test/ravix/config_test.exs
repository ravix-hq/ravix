defmodule Ravix.ConfigTest do
  # Not async: `Ravix.Config` reads the application environment, which is
  # global, and every test here changes it.
  use ExUnit.Case, async: false

  alias Ravix.Config
  alias Ravix.Config.GitHubApp

  # Set one value for this test and put the previous one back afterwards.
  defp override(key, value) do
    previous = Config.put(key, value)
    on_exit(fn -> Config.put(key, previous) end)
  end

  defp override_all(pairs), do: Enum.each(pairs, fn {k, v} -> override(k, v) end)

  describe "github/0" do
    @required [github_app_id: "1", github_client_id: "Iv1.x", github_client_secret: "s"]

    test "the GitHub App is all present or entirely absent" do
      override_all(@required ++ [github_private_key: Ravix.GitHubFake.private_key_pem()])
      assert %GitHubApp{app_id: "1", client_id: "Iv1.x", client_secret: "s"} = Config.github()

      # A half-configured App is the worst state: sign-in works, repositories
      # do not, and the failure surfaces four screens later as an empty list.
      for missing <- [
            :github_app_id,
            :github_client_id,
            :github_client_secret,
            :github_private_key
          ] do
        previous = Config.put(missing, nil)
        assert Config.github() == nil, "#{missing} unset should disable the App"
        Config.put(missing, "  ")
        assert Config.github() == nil, "#{missing} blank should disable the App"
        Config.put(missing, previous)
      end
    end

    test "defaults and trimming" do
      override_all(
        @required ++
          [
            github_private_key: Ravix.GitHubFake.private_key_pem(),
            github_app_slug: nil,
            github_webhook_secret: " ",
            github_api_url: "https://api.github.test/",
            github_web_url: nil
          ]
      )

      app = Config.github()
      assert app.slug == "ravix"
      assert app.webhook_secret == nil
      assert app.api_url == "https://api.github.test"
      assert app.web_url == "https://github.com"
      assert String.starts_with?(app.private_key_pem, "-----BEGIN RSA PRIVATE KEY-----\n")

      override_all(
        github_app_slug: " my-app ",
        github_webhook_secret: "wh",
        github_web_url: "https://gh.test/"
      )

      app = Config.github()
      assert app.slug == "my-app"
      assert app.webhook_secret == "wh"
      assert app.web_url == "https://gh.test"
      assert app.api_url == "https://api.github.test"
    end
  end

  describe "normalize_pem/1" do
    test "a PEM survives every mangling a secret store applies to it" do
      # Literal newlines, `\n` escapes, surrounding quotes and the whole thing
      # on one line all arrive here from Kubernetes Secrets, .env files and
      # GitHub Actions respectively. All three have to work: the alternative
      # is a deployment that fails with a DECODER error naming none of them.
      canonical = Ravix.GitHubFake.private_key_pem() |> String.trim()
      assert Config.normalize_pem(canonical) == canonical
      assert Config.normalize_pem(String.replace(canonical, "\n", "\\n")) == canonical

      assert Config.normalize_pem("\"" <> String.replace(canonical, "\n", "\\n") <> "\"") ==
               canonical

      assert Config.normalize_pem(String.replace(canonical, "\n", "\r\n")) == canonical

      one_line = canonical |> String.replace("\n", " ") |> String.replace(~r/\s+/, " ")
      rewrapped = Config.normalize_pem(one_line)
      assert String.starts_with?(rewrapped, "-----BEGIN RSA PRIVATE KEY-----\n")
      assert String.ends_with?(rewrapped, "\n-----END RSA PRIVATE KEY-----")
      assert String.replace(rewrapped, ~r/\s+/, "") == String.replace(canonical, ~r/\s+/, "")
      # Rewrapped at 64 columns, so the key reads back.
      assert rewrapped |> String.split("\n") |> Enum.all?(&(String.length(&1) <= 64))
      assert %JOSE.JWK{} = JOSE.JWK.from_pem(rewrapped)
    end

    test "a string that is not a PEM comes back trimmed and otherwise untouched" do
      assert Config.normalize_pem("  not a key  ") == "not a key"
    end
  end

  describe "previews/0" do
    test "nil without a PREVIEW_DOMAIN" do
      override(:preview_domain, nil)
      assert Config.previews() == nil
      override(:preview_domain, "  ")
      assert Config.previews() == nil
    end

    test "a *.localhost domain is plain HTTP on the server's own port" do
      override_all(
        preview_domain: " Preview.Localhost ",
        public_url: "http://localhost:5183",
        port: 5183
      )

      assert Config.previews() == %{
               domain: "preview.localhost",
               protocol: :http,
               public_port: ":5183"
             }
    end

    test "a real domain is HTTPS with no port" do
      override_all(preview_domain: "ravix-preview.dev", public_url: "https://app.ravix.sh")

      assert Config.previews() == %{
               domain: "ravix-preview.dev",
               protocol: :https,
               public_port: ""
             }
    end

    test "the domain must be dedicated: not the app host, not under it, not above it" do
      override(:public_url, "https://app.ravix.sh")

      for bad <- ["app.ravix.sh", "p.app.ravix.sh", "ravix.sh", "not a domain", "nodot", "-x.dev"] do
        override(:preview_domain, bad)

        assert_raise RuntimeError, ~r/dedicated domain/, fn -> Config.previews() end
      end
    end

    test "under localhost, any other domain is allowed" do
      override_all(public_url: "http://localhost:4000", preview_domain: "p.localhost.dev")
      assert %{domain: "p.localhost.dev", protocol: :https} = Config.previews()
    end
  end

  describe "fountain/0" do
    test "defaults to managoat.com with no key" do
      override_all(fountain_url: nil, fountain_api_key: nil)
      assert Config.fountain() == %{url: "https://managoat.com", key: nil}
      override_all(fountain_url: "https://fountain.test/ ", fountain_api_key: " ")
      assert Config.fountain() == %{url: "https://fountain.test", key: nil}
      override(:fountain_api_key, " fk ")
      assert Config.fountain().key == "fk"
    end
  end

  describe "sprites/0" do
    test "Sprites is genuinely optional" do
      override_all(sprites_token: nil, sprites_url: nil)
      assert Config.sprites() == nil
      override(:sprites_token, "t")
      assert Config.sprites() == %{token: "t", base_url: "https://api.sprites.dev"}
      override(:sprites_url, "http://sprites.test/")
      assert Config.sprites() == %{token: "t", base_url: "http://sprites.test"}
    end
  end

  describe "the rest" do
    test "public_url/0 falls back to localhost and drops a trailing slash" do
      override(:public_url, nil)
      assert Config.public_url() == "http://localhost:4000"
      override(:public_url, "https://app.ravix.sh/")
      assert Config.public_url() == "https://app.ravix.sh"
    end

    test "secret/0 raises when unset" do
      override(:secret, nil)
      assert_raise RuntimeError, ~r/RAVIX_SECRET/, fn -> Config.secret() end
    end

    test "port/0 defaults to 4000" do
      override(:port, nil)
      assert Config.port() == 4000
    end
  end
end
