import Config
config :ravix, :threads_enabled, true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ravix, Ravix.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("RAVIX_TEST_DATABASE_PORT", "5432")),
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

# Spans are built but exported nowhere; `Ravix.TraceCase` swaps in the in-memory
# exporter for the suites that assert on them. `:simple` rather than `:batch` so
# a span is handed to the processor when it ends rather than on a timer, which is
# the difference between an assertion and a sleep.
#
# The sampler is put back to the SDK's default, undoing `config/config.exs`'s
# `:always_off`: under test the cost of building a span is not the concern and
# there would otherwise be nothing to assert on. Parent-based rather than
# `always_on`, because `Ravix.Trace.untraced/1` works *by* the parent-based
# sampler dropping the children of a non-sampled parent -- with `always_on`
# there would be no suppression to test.
config :opentelemetry,
  span_processor: :simple,
  traces_exporter: :none,
  sampler: {:parent_based, %{root: :always_on}}

# Captured events stay in memory for assertions instead of going to PostHog.
# `PostHog.Test` traces them back to the test that captured them through
# `NimbleOwnership`, so async suites do not see each other's events.
# `enable: true` undoes `config/config.exs`, because `test_mode` keeps events in
# memory but they still travel through a real sender, and the sender lives under
# the supervisor that `enable: false` would not start. The key is never used: in
# test mode nothing is sent.
config :posthog,
  enable: true,
  test_mode: true,
  api_key: "phc_test_mode_never_sent"

config :ravix, Ravix.Schedules.Server, interval: false
