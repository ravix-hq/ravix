# The `:test_coverage` configuration, read by mix.exs and by CI's gate.
# `:ignore_modules` matches module names: OTP boilerplate the runtime
# exercises rather than the suite.
[
  summary: [threshold: 85],
  ignore_modules: [
    Ravix.Application,
    Ravix.Repo,
    Ravix.Release,
    RavixWeb.Telemetry
  ]
]
