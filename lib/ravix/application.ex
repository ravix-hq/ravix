defmodule Ravix.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RavixWeb.Telemetry,
      Ravix.Repo,
      {DNSCluster, query: Application.get_env(:ravix, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Ravix.PubSub},
      # Unlinked, supervised background work; never `Task.async` for fire-and-forget.
      {Task.Supervisor, name: Ravix.TaskSupervisor},
      # Fountain's conversation list and sprite names, memoised briefly.
      Ravix.MachineCache,
      # Who is looking at which track, and who is typing.
      Ravix.Presence,
      # One follower per track -- per cluster, not per instance (ADR 0003): the
      # name is a `:global` one, so this supervisor holds whichever tracks were
      # first opened against this instance. It keeps Fountain's conversation
      # stream open while anyone anywhere is looking at the transcript.
      {DynamicSupervisor, name: Ravix.Tracks.Follower.Supervisor, strategy: :one_for_one},
      # Installation tokens, per-installation rate limits and the checks cache.
      Ravix.GitHub.Cache,
      # Accepted prompts awaiting delivery, swept every two seconds. The
      # sweep is off under test (config/test.exs): a timer outside the SQL
      # sandbox would race every test that owns a connection.
      {Ravix.PromptQueue.Server, Application.get_env(:ravix, Ravix.PromptQueue.Server, [])},
      # Start to serve requests, typically the last entry
      RavixWeb.Endpoint
    ]

    # One process per track preview, its registry, and the reconciler tick.
    children = List.insert_at(children, -2, Ravix.Previews.child_specs()) |> List.flatten()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ravix.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RavixWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
