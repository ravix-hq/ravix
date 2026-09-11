defmodule Ravix.Config do
  @moduledoc """
  The server's configuration, from the environment.

  Ravix needs a fair amount of it, and the reason is the one structural
  difference: **the browser holds no credential for anything**. Sign-in is
  GitHub, so nobody here has a Fountain account to spend; every machine runs
  on this server's Fountain key. That puts four separate secrets in this
  process, and the README says why under "Whose account is this".

  `config/runtime.exs` reads the environment into `config :ravix, Ravix.Config`
  and everything here is a typed reader over that keyword list. Read at call
  time, never cached, so a test can `put/2` a value for one test and put it
  back.

  The GitHub App is all or nothing: a half-configured App is the worst state
  to be in (sign-in works, repositories do not, and the failure surfaces four
  screens later as an empty list). So `github/0` is `nil` unless all five
  values are present.

  ## Why these are structs

  Every reader that carries a credential answers with a struct that derives
  `Inspect` without it. "Do not put credentials in logs" was a rule somebody
  had to remember at each call site; a redacting `Inspect` makes it a
  property of the value, so a crash report, a `Logger` line interpolating a
  struct, or a LiveView dumping its assigns cannot print one. A bare map
  cannot derive a protocol, which is the whole reason `sprites/0` and
  `fountain/0` stopped returning one.

  This is the same mechanism the four credential-bearing Ecto schemas use,
  and `Ravix.Fountain.Client` hides the SDK's config for the same reason.
  """

  defmodule GitHubApp do
    @moduledoc """
    The GitHub App registration, complete or absent.

    Two of these seven fields sign things, and the `Inspect` derive is why
    they are safe to hold in a struct that gets passed around: a crash
    report, a `Logger` line or a `dbg/1` left in prints `...` for them
    rather than a usable secret. See `Ravix.Config`'s note on redaction.
    """
    @derive {Inspect, except: [:client_secret, :private_key_pem]}
    @type t :: %__MODULE__{
            app_id: String.t(),
            slug: String.t(),
            client_id: String.t(),
            client_secret: String.t(),
            private_key_pem: String.t(),
            api_url: String.t(),
            web_url: String.t()
          }
    defstruct [
      :app_id,
      :slug,
      :client_id,
      :client_secret,
      :private_key_pem,
      :api_url,
      :web_url
    ]
  end

  defmodule Sprites do
    @moduledoc """
    Sprites: where it is and the token every exec, service and tunnel runs on.

    A struct rather than the `%{token: ..., base_url: ...}` map it was,
    because a bare map cannot derive `Inspect` and this one is handed to
    `Ravix.Sprites.Tunnel.open/4` and every `Ravix.Sprites` call.
    """
    @derive {Inspect, except: [:token]}
    @type t :: %__MODULE__{token: String.t(), base_url: String.t()}
    @enforce_keys [:token, :base_url]
    defstruct [:token, :base_url]
  end

  defmodule Fountain do
    @moduledoc """
    Fountain: where it is, and the one account every machine is built on.

    `key` is nil on a deployment without machines, which is what
    `Ravix.Fountain.Client.new/3` turns into an unconfigured client.
    """
    @derive {Inspect, except: [:key]}
    @type t :: %__MODULE__{url: String.t(), key: String.t() | nil}
    @enforce_keys [:url, :key]
    defstruct [:url, :key]
  end

  defmodule Previews do
    @moduledoc """
    Where track previews are served: the dedicated domain, the scheme, and
    the `:port` suffix a local domain needs.

    A struct like its three siblings above, and for the second half of the
    same reason. Those are structs because a bare map cannot derive a
    redacting `Inspect` and they carry credentials; this one carries none,
    so it stayed a map -- which left the one reader in this module whose
    answer a typo reaches silently. `@enforce_keys` is what makes a field
    added here a build error at the two places that compose a preview host
    rather than an `"...nil"` in a URL.

    `public_port` is `""` or `":4000"`, ready to concatenate: the suffix is
    part of the host a browser is sent to, and an integer here would be
    formatted at each of the three call sites instead of once.
    """

    @enforce_keys [:domain, :protocol, :public_port]
    defstruct [:domain, :protocol, :public_port]

    @type t :: %__MODULE__{
            domain: String.t(),
            protocol: :https | :http,
            public_port: String.t()
          }
  end

  @typedoc "Deprecated spelling of `t:Ravix.Config.Previews.t/0`."
  @type previews :: Previews.t()

  @doc "The raw configuration keyword list."
  @spec all() :: keyword()
  def all, do: Application.get_env(:ravix, __MODULE__, [])

  @doc "One value, for tests to override with `put/2`."
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil), do: Keyword.get(all(), key, default)

  @doc "Set one value (tests). Returns the previous value so it can be restored."
  @spec put(atom(), term()) :: term()
  def put(key, value) do
    previous = get(key)
    Application.put_env(:ravix, __MODULE__, Keyword.put(all(), key, value))
    previous
  end

  @doc "This server as GitHub and browsers reach it, without a trailing slash."
  @spec public_url() :: String.t()
  def public_url,
    do:
      get(:public_url)
      |> blank_to(nil)
      |> Kernel.||("http://localhost:4000")
      |> String.trim_trailing("/")

  @doc "The AES key material for stored tokens. At least sixteen characters."
  @spec secret() :: String.t()
  def secret, do: get(:secret) || raise("RAVIX_SECRET is not configured")

  @doc "Fountain: where it is and the account every machine is built on (nil key means no machines)."
  @spec fountain() :: Fountain.t()
  def fountain do
    %Fountain{
      url:
        (get(:fountain_url) |> blank_to(nil) || "https://managoat.com")
        |> String.trim_trailing("/"),
      key: get(:fountain_api_key) |> blank_to(nil)
    }
  end

  @doc "Sprites, or nil: without a token the terminal, run panel and previews say so."
  @spec sprites() :: Sprites.t() | nil
  def sprites do
    case get(:sprites_token) |> blank_to(nil) do
      nil ->
        nil

      token ->
        %Sprites{
          token: token,
          base_url:
            (get(:sprites_url) |> blank_to(nil) || "https://api.sprites.dev")
            |> String.trim_trailing("/")
        }
    end
  end

  @doc "The GitHub App, complete, or nil."
  @spec github() :: GitHubApp.t() | nil
  def github do
    with app_id when is_binary(app_id) <- get(:github_app_id) |> blank_to(nil),
         client_id when is_binary(client_id) <- get(:github_client_id) |> blank_to(nil),
         client_secret when is_binary(client_secret) <-
           get(:github_client_secret) |> blank_to(nil),
         raw_key when is_binary(raw_key) <- get(:github_private_key) |> blank_to(nil),
         pem when is_binary(pem) <- signing_pem(raw_key) do
      %GitHubApp{
        app_id: app_id,
        slug: get(:github_app_slug) |> blank_to(nil) || "ravix",
        client_id: client_id,
        client_secret: client_secret,
        private_key_pem: pem,
        # Carried for a webhook receiver that does not exist yet; nothing
        # reads it, so no payload is being verified against it today.
        api_url:
          (get(:github_api_url) |> blank_to(nil) || "https://api.github.com")
          |> String.trim_trailing("/"),
        web_url:
          (get(:github_web_url) |> blank_to(nil) || "https://github.com")
          |> String.trim_trailing("/")
      }
    else
      _ -> nil
    end
  end

  # All of them or none of them, and a key that cannot sign is none of them.
  # Sign-in uses the client secret rather than the key, so a bad PEM leaves an
  # App that looks complete and works right up to the first repository call,
  # which raises out of JOSE instead of returning a tagged error. Checking it
  # here is what keeps `github/0` the single all-or-nothing answer it claims.
  defp signing_pem(raw_key) do
    pem = normalize_pem(raw_key)

    case JOSE.JWK.from_pem(pem) do
      %JOSE.JWK{} = jwk -> if signer?(jwk), do: pem
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp signer?(jwk) do
    JOSE.JWT.sign(jwk, %{"alg" => "RS256"}, %{"probe" => 1})
    true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  Track previews, or nil when `PREVIEW_DOMAIN` is unset.

  Preview hosts are `<name>.<domain><public_port>`. The domain must be a
  dedicated one outside the application host: not the app host, not under it,
  and not above it. That is ancestry, which is less than it sounds -- cookie
  scope is decided by the registrable domain, and `preview.ravix.sh` is a
  sibling of `app.ravix.sh`, not a stranger to it, so a `Domain=ravix.sh`
  cookie reaches both. Keeping a preview out of the app's cookies is
  therefore the gateway's job rather than this check's:
  `RavixWeb.PreviewGateway.Headers` strips any `Domain` attribute and refuses
  to relay a `Set-Cookie` naming the app's session cookie at all.

  `*.localhost` domains use plain HTTP on the server's own port, for local
  development only.
  """
  @spec previews() :: Previews.t() | nil
  def previews do
    case get(:preview_domain) |> blank_to(nil) do
      nil ->
        nil

      raw ->
        domain = raw |> String.trim() |> String.downcase()
        app_host = URI.parse(public_url()).host || "localhost"

        unless dedicated_domain?(domain, app_host),
          do:
            raise("PREVIEW_DOMAIN must be a dedicated domain outside the Ravix application host.")

        if String.ends_with?(domain, ".localhost") do
          %Previews{
            domain: domain,
            protocol: :http,
            public_port: ":" <> Integer.to_string(port())
          }
        else
          %Previews{domain: domain, protocol: :https, public_port: ""}
        end
    end
  end

  # A preview domain that is not the app's host, not under it, and not above it.
  defp dedicated_domain?(domain, app_host) do
    Regex.match?(~r/^[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z]+$/, domain) and domain != app_host and
      (app_host == "localhost" or not String.ends_with?(domain, "." <> app_host)) and
      not String.ends_with?(app_host, "." <> domain)
  end

  @doc "The one listen port."
  @spec port() :: pos_integer()
  def port, do: get(:port) || 4000

  @doc "How long a session cookie lives."
  @spec session_max_age_ms() :: pos_integer()
  def session_max_age_ms, do: 30 * 24 * 60 * 60 * 1000

  @doc """
  A PEM as it survives being put in a secret store.

  Kubernetes Secrets, `.env` files, GitHub Actions secrets and a shell heredoc
  each preserve a different amount of the original: literal newlines, `\\n`
  escapes, or the whole thing on one line with the header and footer intact.
  All three arrive here and all three have to work.
  """
  @spec normalize_pem(String.t()) :: String.t()
  def normalize_pem(raw) do
    s = String.trim(raw)

    s =
      if String.starts_with?(s, "\"") and String.ends_with?(s, "\""),
        do: String.slice(s, 1..-2//1),
        else: s

    s = s |> String.replace("\\n", "\n") |> String.replace("\r\n", "\n") |> String.trim()

    if String.contains?(s, "\n") do
      s
    else
      case Regex.run(~r/^(-----BEGIN [A-Z ]+-----)\s*(.*?)\s*(-----END [A-Z ]+-----)$/, s) do
        [_, header, body, footer] ->
          lines = body |> String.replace(~r/\s+/, "") |> chunk(64)
          Enum.join([header | lines] ++ [footer], "\n")

        _ ->
          s
      end
    end
  end

  defp chunk(string, size) do
    string |> String.graphemes() |> Enum.chunk_every(size) |> Enum.map(&Enum.join/1)
  end

  defp blank_to(nil, default), do: default

  defp blank_to(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp blank_to(value, _default), do: value
end
