# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ravix,
  ecto_repos: [Ravix.Repo],
  generators: [timestamp_type: :utc_datetime],
  # The preview gateway's window onto the previews context.
  preview_backend: RavixWeb.PreviewGateway.RavixBackend

# Configure the endpoint
config :ravix, RavixWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RavixWeb.ErrorHTML, json: RavixWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ravix.PubSub,
  live_view: [signing_salt: "XINyaMNB"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ravix: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Tracing (ADR 0004). **Inert unless a deployment configures an exporter**, and
# it takes both of these lines to mean that rather than just the first.
#
# `traces_exporter: :none` stops spans leaving the process, but it does not stop
# them being made: `otel_batch_processor:on_end/2` buffers every *sampled* span
# whatever the exporter is, and the SDK's default root sampler is `always_on`.
# So the exporter alone would leave an unconfigured deployment building a span,
# running `Ravix.Trace.sanitize/1` and writing to an ETS table on every request,
# LiveView event and query -- then dropping the lot on a five-second timer. No
# egress and no log noise, but real work for nothing.
#
# `sampler: :always_off` is what makes it actually nothing. An unsampled span is
# non-recording, so no attributes are built and `on_end/2` answers `dropped`
# before the buffer. `config/runtime.exs` replaces both lines when
# HONEYCOMB_API_KEY is present; `config/test.exs` replaces the sampler alone, so
# that `Ravix.TraceCase` has spans to read back.
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :none,
  sampler: :always_off,
  resource: [service: [name: "ravix"]]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
