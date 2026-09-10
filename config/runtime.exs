import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/ravix start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :ravix, RavixWeb.Endpoint, server: true
end

port = String.to_integer(System.get_env("PORT", "4000"))
config :ravix, RavixWeb.Endpoint, http: [port: port]

# Ravix's own configuration, the same names the TypeScript server read. Every
# reader is in `Ravix.Config`; nothing else touches the environment.
env = fn name -> System.get_env(name) end

# Checked here rather than at first use: `Ravix.Crypto` raises on a short
# secret, and its only caller is the OAuth callback, so a deploy would go
# green and fail on everyone's sign-in.
ravix_secret = fn secret ->
  if String.length(secret) < 16,
    do: raise("environment variable RAVIX_SECRET must be at least 16 characters"),
    else: secret
end

config :ravix, Ravix.Config,
  port: port,
  public_url: env.("PUBLIC_URL"),
  secret:
    (env.("RAVIX_SECRET") && ravix_secret.(env.("RAVIX_SECRET"))) ||
      if(config_env() != :prod,
        do: "ravix-development-secret-not-for-production",
        else:
          raise("""
          environment variable RAVIX_SECRET is missing.

          It encrypts stored GitHub tokens, so without it the app boots, passes
          its health check, serves the landing page, and then raises on the
          OAuth callback -- nobody can sign in, and the deploy reports success.
          Generate one with: mix phx.gen.secret
          """)
      ),
  fountain_url: env.("FOUNTAIN_URL"),
  fountain_api_key: env.("FOUNTAIN_API_KEY"),
  github_app_id: env.("GITHUB_APP_ID"),
  github_app_slug: env.("GITHUB_APP_SLUG"),
  github_client_id: env.("GITHUB_CLIENT_ID"),
  github_client_secret: env.("GITHUB_CLIENT_SECRET"),
  github_private_key: env.("GITHUB_PRIVATE_KEY"),
  github_api_url: env.("GITHUB_API_URL"),
  github_web_url: env.("GITHUB_WEB_URL"),
  sprites_token: env.("SPRITES_TOKEN"),
  sprites_url: env.("SPRITES_URL"),
  preview_domain: env.("PREVIEW_DOMAIN")

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :ravix, Ravix.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    # A high-availability failover terminates every connection at once and the
    # standby answers at the same URL a moment later (ADR 0003). Postgrex
    # reconnects on its own; what these two decide is what happens to the
    # requests that arrive during the gap. The default `queue_target` of 50ms
    # makes DBConnection start refusing checkouts as soon as the pool is slow,
    # which turns a few seconds of failover into errors on pages that would have
    # been served by waiting. Wait instead, up to two seconds.
    queue_target: 200,
    queue_interval: 2_000,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  # Cookies and LiveView sessions are signed with SECRET_KEY_BASE; RAVIX_SECRET
  # stands in when it is unset, so one generated secret runs the deployment.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      case System.get_env("RAVIX_SECRET") do
        nil -> raise "environment variable SECRET_KEY_BASE (or RAVIX_SECRET) is missing"
        secret -> :crypto.hash(:sha512, secret) |> Base.encode64()
      end

  host = (System.get_env("PUBLIC_URL") || "https://app.ravix.sh") |> URI.parse() |> Map.get(:host)

  # How the instances of this service find each other (ADR 0003). Render sets
  # RENDER_DISCOVERY_SERVICE to a DNS name whose A records are every instance of
  # the service, which is exactly what `DNSCluster` wants; DNS_CLUSTER_QUERY
  # still wins, for a deployment that names its own. Unset on one instance, and
  # then `Ravix.Application` starts `DNSCluster` with `:ignore`.
  #
  # `rel/env.sh.eex` is the other half: without a `name` distribution and a node
  # named for this address, there is nothing here for a sibling to connect to.
  config :ravix,
         :dns_cluster_query,
         System.get_env("DNS_CLUSTER_QUERY") || System.get_env("RENDER_DISCOVERY_SERVICE")

  config :ravix, RavixWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      # How long a draining instance keeps serving the connections it already
      # has (ADR 0003). Explicit because it is load-bearing on every deploy and
      # it is half of a pair: `render.yaml`'s `maxShutdownDelaySeconds` is the
      # other half and has to be the larger of the two, or Render kills the
      # container mid-drain and the connections this window exists to protect
      # are dropped anyway. Bandit's own default is 15s.
      #
      # A LiveView socket never "completes", so what this really buys is that
      # somebody mid-sentence when the deploy started keeps a working page for
      # twenty more seconds and then reconnects to a new instance, rather than
      # being cut off the moment the swap begins. The endpoint is the last child
      # in `Ravix.Application`, so it drains before the followers and preview
      # servers those pages are talking to go away.
      thousand_island_options: [shutdown_timeout: 20_000]
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :ravix, RavixWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :ravix, RavixWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
