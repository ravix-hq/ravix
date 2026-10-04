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
        services(),
        {DNSCluster, query: Application.get_env(:ravix, :dns_cluster_query) || :ignore},
        # Says in the log who this instance can see, because clustering is the one
        # thing here that fails silently and a shell is not always available to
        # ask (ADR 0003).
        Ravix.Cluster.Watch,
        {DynamicSupervisor, name: Ravix.Tooling.Wait.Supervisor, strategy: :one_for_one},
        # Who is looking at which track, and who is typing.
        Ravix.Presence,
        # One follower per track -- per cluster, not per instance (ADR 0003): the
        # name is a `:global` one, so this supervisor holds whichever tracks were
        # first opened against this instance. It keeps Fountain's conversation
        # stream open while anyone anywhere is looking at the transcript.
        {DynamicSupervisor, name: Ravix.Tracks.Follower.Supervisor, strategy: :one_for_one},
        # One process per open terminal tab per page, on this instance only: the
        # shell itself lives on the sprite and any instance may attach to it.
        # See `Ravix.Terminal.Shell` for why this is not a `:global` name.
        {Registry, keys: :unique, name: Ravix.Terminal.Registry},
        {DynamicSupervisor, name: Ravix.Terminal.Supervisor, strategy: :one_for_one},
        {Ravix.Cluster.Singleton,
         key: "tooling.tasks",
         child:
           {Ravix.Tooling.Reconciler, Application.get_env(:ravix, Ravix.Tooling.Reconciler, [])}},
        # One process per track preview, its registry, and the reconciler tick.
        Ravix.Previews.child_specs(),
        {Ravix.Cluster.Singleton,
         key: "schedules",
         child: {Ravix.Schedules.Server, Application.get_env(:ravix, Ravix.Schedules.Server, [])}},
        {Ravix.Cluster.Singleton,
         key: "track.sandboxes",
         child:
           {Ravix.Tracks.Sandbox.Reconciler,
            Application.get_env(:ravix, Ravix.Tracks.Sandbox.Reconciler, [])}},
        # A running turn's GitHub token, re-minted before the hour it lives runs out.
        {Ravix.Cluster.Singleton,
         key: "track.clone_tokens",
         child:
           {Ravix.Tracks.Sandbox.CloneTokens,
            Application.get_env(:ravix, Ravix.Tracks.Sandbox.CloneTokens, [])}},
        # Start to serve requests, typically the last entry
        RavixWeb.Endpoint,
        # Stop claiming before draining the endpoint (20s). Queue shutdown is
        # capped at 5s, leaving 5s of Render's 30s for the remaining children.
        {Ravix.PromptQueue.Server, Application.get_env(:ravix, Ravix.PromptQueue.Server, [])}
      ]
      |> List.flatten()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ravix.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  What a context call needs to run at all, and nothing that does work of its
  own: the Repo, PubSub, the task supervisor and the caches. No endpoint, no
  scheduler, no `Ravix.Cluster.Singleton`, nothing that joins the cluster.

  The instance starts these first. A one-off release task starts only these
  (`Ravix.Release.start_services/0`), because a task run with `bin/ravix
  eval` is a node of its own, `nonode@nohost`, that sees no cluster: every
  singleton it started would run beside production's rather than wait for
  it. So anything added here must be passive -- it may answer calls, and
  must not start work on a timer.
  """
  @spec services() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def services do
    [
      Ravix.Repo,
      {Phoenix.PubSub, name: Ravix.PubSub},
      # Unlinked, supervised background work; never `Task.async` for fire-and-forget.
      {Task.Supervisor, name: Ravix.TaskSupervisor},
      # Fountain's conversation list and sprite names, memoised briefly.
      Ravix.MachineCache,
      {Ravix.Memo, name: Ravix.Accounts.Inference.Cache.Reads},
      Ravix.Accounts.Inference.Cache,
      # Installation tokens and per-installation rate limits, plus the memo
      # that shares one checks read between every row asking about a branch.
      Ravix.GitHub.Cache,
      {Ravix.Memo, name: Ravix.GitHub.Cache.Checks},
      {Ravix.Memo, name: Ravix.GitHub.Reads}
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RavixWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
