defmodule Ravix.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Ravix.Trace

  @impl true
  def start(_type, _args) do
    # Before the endpoint, and before anything below can do work worth tracing:
    # a telemetry handler attached after the first request is one that missed it.
    Trace.Setup.setup()

    children =
      [
        RavixWeb.Telemetry,
        Ravix.Repo,
        {DNSCluster, query: Application.get_env(:ravix, :dns_cluster_query) || :ignore},
        # Says in the log who this instance can see, because clustering is the one
        # thing here that fails silently and a shell is not always available to
        # ask (ADR 0003).
        Ravix.Cluster.Watch,
        {Phoenix.PubSub, name: Ravix.PubSub},
        # Unlinked, supervised background work; never `Task.async` for fire-and-forget.
        {Task.Supervisor, name: Ravix.TaskSupervisor},
        {DynamicSupervisor, name: Ravix.Tooling.Wait.Supervisor, strategy: :one_for_one},
        # Fountain's conversation list and sprite names, memoised briefly.
        Ravix.MachineCache,
        {Ravix.Memo, name: Ravix.Accounts.Inference.Cache.Reads},
        Ravix.Accounts.Inference.Cache,
        # Who is looking at which track, and who is typing.
        Ravix.Presence,
        # One follower per track -- per cluster, not per instance (ADR 0003): the
        # name is a `:global` one, so this supervisor holds whichever tracks were
        # first opened against this instance. It keeps Fountain's conversation
        # stream open while anyone anywhere is looking at the transcript.
        {DynamicSupervisor, name: Ravix.Tracks.Follower.Supervisor, strategy: :one_for_one},
        # Installation tokens and per-installation rate limits, plus the memo
        # that shares one checks read between every row asking about a branch.
        Ravix.GitHub.Cache,
        {Ravix.Memo, name: Ravix.GitHub.Cache.Checks},
        {Ravix.Memo, name: Ravix.GitHub.Reads},
        # Accepted prompts awaiting delivery, swept on a timer and on the
        # turn that frees a thread the queue is waiting on. The
        # sweep is off under test (config/test.exs): a timer outside the SQL
        # sandbox would race every test that owns a connection.
        {Ravix.PromptQueue.Server, Application.get_env(:ravix, Ravix.PromptQueue.Server, [])},
        # One process per track preview, its registry, and the reconciler tick.
        Ravix.Previews.child_specs(),
        {Ravix.Cluster.Singleton,
         key: "schedules",
         child: {Ravix.Schedules.Server, Application.get_env(:ravix, Ravix.Schedules.Server, [])}},
        # Start to serve requests, typically the last entry
        RavixWeb.Endpoint
      ]
      |> List.flatten()

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
