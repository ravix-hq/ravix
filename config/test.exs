import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ravix, Ravix.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ravix_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ravix, RavixWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "uQgmHWsqVaGYNBJIE2enAlyaGr5GQsVlFj+gumX8LkbkTqFep24rzPVpG5+AJXF6",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Every Req client (GitHub, Sprites) merges this into its requests, so one
# Req.Test stub name serves both suites; stubs are per process, so async is fine.
config :ravix, :req_options, plug: {Req.Test, Ravix.ReqFake}

# Background sweeps stay off under test; tests drive `tick/0` themselves.
config :ravix, Ravix.PromptQueue.Server, interval: false

# Spans are built but exported nowhere; `Ravix.TraceCase` swaps in the
# in-memory exporter for the suites that assert on them. `:simple` rather than
# `:batch` so a span is handed to the processor when it ends rather than on a
# timer, which is the difference between an assertion and a sleep.
config :opentelemetry, span_processor: :simple, traces_exporter: :none
