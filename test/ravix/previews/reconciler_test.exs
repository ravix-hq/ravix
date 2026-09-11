defmodule Ravix.Previews.ReconcilerTest do
  @moduledoc """
  The orchestration tests of `server/previews.test.ts`: starts, stops,
  reconfigurations, the reconciler's tick, and everything that must not
  publish a stale service as Ready. The provider is the scripted one in
  `Ravix.PreviewsFixture`; the clock is the fixture's, moved by hand.
  """
  use Ravix.DataCase, async: true, group: :preview_ports
  use Mimic
  use ExUnitProperties

  import Ravix.PreviewsFixture

  alias Ravix.Previews
  alias Ravix.Previews.{Config, Reconciler, Row, Store}
  alias Ravix.QueryCount
  alias Ravix.Tracks.Track

  @config %{
    "directory" => "apps/demo",
    "command" => ~s(npm run dev -- --port "$PORT" --strictPort),
    "readinessPath" => "/health"
  }

  setup do
    start_tree()
    provider = start_provider()
    stub_provider(provider)
    owner = insert_user()
    project = insert_project(user: owner)
    t1 = insert_track(project: project, conversation_id: "c1")
    t2 = insert_track(project: project, conversation_id: "c2")
    insert_preview_default(project, config: @config)
    %{p: provider, owner: owner, project: project, t1: t1, t2: t2}
  end

  defp service_id(track_id) do
    %Row{sprite: sprite, service: service} = Store.get(track_id)
    "#{sprite}/#{service}"
  end

  defp parallel(funs) do
    funs |> Enum.map(&Task.async/1) |> Task.await_many(30_000)
  end

  describe "the reconciler walks a preview through its life" do
    test "stopped, starting, ready, held while viewed, left alone when the lease lapses, stopped when idle",
         %{p: p, t1: t1} do
      assert %{state: :stopped, available: true} = Previews.info(t1.id)

      # Readiness is asked twice: the first probe sees the service starting.
      {:ok, probes} = Agent.start_link(fn -> 0 end)

      put(p, :ready, fn ->
        n = Agent.get_and_update(probes, &{&1 + 1, &1 + 1})
        if n == 1, do: assert(%{state: :starting} = Previews.info(t1.id))
        n > 1
      end)

      assert :ok = Previews.start_service(t1.id)
      assert Agent.get(probes, & &1) == 2
      assert %{state: :ready, error: nil} = Previews.info(t1.id)

      row = Store.get(t1.id)
      assert row.port == 20_000 and row.sprite == "s1" and row.desired == :running
      assert String.starts_with?(row.hostname, "t-")
      assert state(p).creates == 1
      assert state(p).services[service_id(t1.id)] == "running"
      # The viewing lease is held, so the sprite's activity task was taken.
      assert state(p).holds == ["#{service_id(t1.id)}/hold"]

      # Within thirty seconds the tick refreshes nothing; after, it renews the hold.
      Reconciler.tick()
      assert length(state(p).holds) == 1
      advance(p, 40_000)
      Reconciler.tick()
      assert length(state(p).holds) == 2
      assert state(p).creates == 1
      assert %{state: :ready} = Previews.info(t1.id)

      # The lease lapses: no health polling, no machine reads, still ready.
      advance(p, 60_000)
      reads = state(p).reads
      Reconciler.tick()
      assert state(p).reads == reads
      assert length(state(p).holds) == 2
      assert %{state: :ready} = Previews.info(t1.id)

      # Five minutes idle: stopped, task released, lease cleared.
      advance(p, 4 * 60_000)
      Reconciler.tick()
      assert %{state: :stopped, error: nil} = Previews.info(t1.id)
      assert %Row{desired: :stopped, lease_until: 0, stop_pending: false} = Store.get(t1.id)
      assert state(p).services[service_id(t1.id)] == "stopped"
      assert List.last(state(p).holds) == "#{service_id(t1.id)}/release"

      # Nothing more happens to a stopped preview.
      Reconciler.tick()
      assert state(p).creates == 1
    end
  end

  test "parallel starts allocate different ports and repeated opens are idempotent", %{
    p: p,
    t1: t1,
    t2: t2
  } do
    parallel([
      fn -> Previews.start_service(t1.id) end,
      fn -> Previews.start_service(t2.id) end,
      fn -> Previews.start_service(t1.id) end
    ])

    a = Store.get(t1.id)
    b = Store.get(t2.id)
    assert a.port != b.port and a.hostname != b.hostname
    assert a.state == :ready and b.state == :ready
    assert state(p).creates == 2

    assert :ok = Previews.stop_service(t1.id)
    assert state(p).services[service_id(t2.id)] == "running"
    assert Store.get(t2.id).state == :ready
  end

  test "a stop during service creation rejects the stale readiness result", %{p: p, t1: t1} do
    put(p, :barrier, true)
    starting = Task.async(fn -> Previews.start_service(t1.id) end)
    await(p, &(&1.creates == 1))

    stopping = Task.async(fn -> Previews.stop_service(t1.id) end)
    await(p, fn _ -> match?(%Row{desired: :stopped}, Store.get(t1.id)) end)
    put(p, :barrier, false)
    Task.await_many([starting, stopping], 30_000)

    assert Store.get(t1.id).state == :stopped
    assert Map.values(state(p).services) == ["stopped"]
  end

  test "configuration change during startup cannot publish an old service as Ready", %{
    p: p,
    t1: t1
  } do
    put(p, :barrier, true)
    starting = Task.async(fn -> Previews.start_service(t1.id) end)
    await(p, &(&1.creates == 1))

    config = %Config{directory: "app2", command: "new command", readiness_path: "/"}
    configuring = Task.async(fn -> Previews.configure(t1.id, config) end)
    await(p, fn _ -> match?(%Row{desired: :stopped}, Store.get(t1.id)) end)
    put(p, :barrier, false)
    Task.await_many([starting, configuring], 30_000)

    assert %{state: :stopped, config: %{directory: "app2"}} = Previews.info(t1.id)
    assert :ok = Previews.start_service(t1.id)
    assert %{state: :ready} = Previews.info(t1.id)
  end

  property "sequences of intent changes cannot be overwritten by an earlier provider response", %{
    p: p,
    project: project
  } do
    check all(
            changes <- list_of(member_of([:stop, :configure]), min_length: 1, max_length: 5),
            max_runs: 20
          ) do
      track = insert_track(project: project, conversation_id: Ecto.UUID.generate())
      put(p, :barrier, true)
      creates = state(p).creates
      starting = Task.async(fn -> Previews.start_service(track.id) end)
      await(p, &(&1.creates == creates + 1))
      initial = Store.get(track.id).generation

      pending =
        for {change, index} <- Enum.with_index(changes, 1) do
          task =
            Task.async(fn ->
              case change do
                :stop ->
                  Previews.stop_service(track.id)

                :configure ->
                  Previews.configure(track.id, %Config{
                    directory: "app#{index}",
                    command: "run #{index}",
                    readiness_path: "/"
                  })
              end
            end)

          await(p, fn _ -> Store.get(track.id).generation == initial + index end)
          task
        end

      put(p, :barrier, false)
      assert Enum.all?(Task.await_many([starting | pending], 5_000), &(&1 == :ok))
      row = Store.get(track.id)
      assert row.generation == initial + length(changes)
      assert row.desired == :stopped
      assert row.state == :stopped
      refute state(p).services[service_id(track.id)] == "running"
      assert :ok = Previews.stop_service(track.id, :cleanup)
    end
  end

  test "port collisions and repeated crashes fail with logs, without an endless restart loop",
       %{p: p, t1: t1} do
    put(p, :collide, true)
    assert :ok = Previews.start_service(t1.id)
    assert %{state: :failed, error: "Port occupied"} = Previews.info(t1.id)
    assert state(p).creates == 0

    put(p, :collide, false)
    put(p, :crash, 3)
    assert :ok = Previews.start_service(t1.id)

    assert %{state: :failed, logs: "Error: command not found", error: error} =
             Previews.info(t1.id)

    assert error =~ "crashed repeatedly"
    assert %Row{desired: :stopped} = Store.get(t1.id)

    created = state(p).creates
    Reconciler.tick()
    assert state(p).creates == created
  end

  test "changing or restarting a stopped service replaces the provider definition instead of accepting its no-op PUT",
       %{p: p, t1: t1, t2: t2} do
    put(p, :define_conflict, true)
    parallel([fn -> Previews.start_service(t1.id) end, fn -> Previews.start_service(t2.id) end])
    peer = service_id(t2.id)
    id = service_id(t1.id)

    assert :ok = Previews.stop_service(t1.id)
    command = ~s(exec new-server --port "$PORT")

    assert :ok =
             Previews.configure(t1.id, %Config{
               directory: "new-app",
               command: command,
               readiness_path: "/"
             })

    assert :ok = Previews.start_service(t1.id)
    assert state(p).definitions[id]["args"] == ["-lc", command]
    assert %{state: :ready, logs: logs} = Previews.info(t1.id)
    refute logs =~ "already running"
    assert length(state(p).deletes) == 1

    assert :ok = Previews.start_service(t1.id, :restart)
    assert length(state(p).deletes) == 2
    assert %{state: :ready} = Previews.info(t1.id)
    assert state(p).services[peer] == "running"
    refute peer in state(p).stops

    %Row{} = row = Store.get(t1.id)
    Store.save!(%{row | logs: "old startup response"})
    assert :ok = Previews.stop_service(t1.id)
    assert :ok = Previews.start_service(t1.id)
    refute Previews.info(t1.id).logs =~ "old startup response"

    # Recover rows already affected on the live deployment: applied_config says
    # the new command was saved, but the provider still holds the old arguments.
    assert :ok = Previews.stop_service(t1.id)
    definition = state(p).definitions[id]

    put(
      p,
      :definitions,
      Map.put(state(p).definitions, id, %{definition | "args" => ["-lc", "old-server"]})
    )

    assert :ok = Previews.start_service(t1.id)
    assert state(p).definitions[id]["args"] == ["-lc", command]
    assert length(state(p).deletes) == 3
  end

  test "restart reconciliation recovers saved intent, replaces sandboxes, and retries an interrupted stop",
       %{p: p, t1: t1} do
    assert :ok = Previews.start_service(t1.id)
    original = Store.get(t1.id)

    # The provider forgot every service (and so would Ravix, after a restart).
    put(p, :services, %{})
    Reconciler.tick()
    assert %{state: :ready} = Previews.info(t1.id)
    assert state(p).creates == 2

    put(p, :sandbox, "s2")
    Reconciler.tick()
    assert %Row{sprite: "s2", sandbox_id: "s2", state: :ready} = Store.get(t1.id)
    assert "s1/#{original.service}" in state(p).deletes

    put(p, :fail_stop, true)
    assert {:error, %Ravix.Sprites.Error{message: "offline"}} = Previews.stop_service(t1.id)
    assert %Row{stop_pending: true, desired: :stopped} = Store.get(t1.id)

    put(p, :fail_stop, false)
    Reconciler.tick()
    assert %Row{stop_pending: false, state: :stopped} = Store.get(t1.id)
  end

  test "lease expiry does not health-poll an idle machine; idle stop and closed-track cleanup preserve peers",
       %{p: p, t1: t1, t2: t2} do
    parallel([fn -> Previews.start_service(t1.id) end, fn -> Previews.start_service(t2.id) end])
    b = Store.get(t2.id)

    # Both leases expire; t2 stays running but is not polled either.
    for id <- [t1.id, t2.id] do
      %Row{} = row = Store.get(id)
      Store.save!(%{row | lease_until: now(p) - 1})
    end

    reads = state(p).reads
    Reconciler.tick()
    assert state(p).reads == reads

    %Row{} = idle = Store.get(t1.id)
    Store.save!(%{idle | last_activity: now(p) - 6 * 60_000})
    Reconciler.tick()
    assert %{state: :stopped} = Previews.info(t1.id)
    assert %{state: :ready} = Previews.info(t2.id)

    assert :ok = Previews.start_service(t1.id)
    assert %{state: :ready} = Previews.info(t1.id)

    Repo.update!(Ecto.Changeset.change(Repo.get!(Track, t1.id), closed_at: DateTime.utc_now()))
    Reconciler.tick()
    assert %Row{port: nil, sprite: nil, cleanup: true} = Store.get(t1.id)
    assert state(p).services["#{b.sprite}/#{b.service}"] == "running"
  end

  test "a sandbox replacement during readiness cannot publish the stale service as Ready", %{
    p: p,
    t1: t1
  } do
    put(p, :ready, fn ->
      put(p, :sandbox, "s2")
      true
    end)

    assert :ok = Previews.start_service(t1.id)
    assert %{state: :failed, error: error} = Previews.info(t1.id)
    assert error =~ "workspace changed"
    assert Map.values(state(p).services) == ["stopped"]
  end

  test "readiness that never passes fails after the startup deadline, on the fixture's clock", %{
    p: p,
    t1: t1
  } do
    put(p, :ready, false)
    before = now(p)
    assert :ok = Previews.start_service(t1.id)
    assert %{state: :failed, error: error} = Previews.info(t1.id)
    assert error =~ "Readiness did not pass at /health on $PORT=20000"
    assert now(p) - before >= 60_000
  end

  test "unconfigured deployments explicitly report previews unavailable", %{t1: t1} do
    stub(Ravix.Config, :previews, fn -> nil end)
    assert %{available: false, unavailable_reason: why, url: nil} = Previews.info(t1.id)
    assert why =~ "PREVIEW_DOMAIN"
    assert {:error, {:unavailable, ^why}} = Previews.start_service(t1.id)
  end

  test "overlapping restart requests discard superseded operations and leave the latest intent running",
       %{p: p, t1: t1} do
    assert :ok = Previews.start_service(t1.id)

    parallel([
      fn -> Previews.start_service(t1.id, :restart) end,
      fn -> Previews.start_service(t1.id, :restart) end,
      fn -> Previews.start_service(t1.id, :restart) end
    ])

    assert state(p).creates >= 2
    assert %{state: :ready} = Previews.info(t1.id)
    assert Map.values(state(p).services) == ["running"]

    parallel([fn -> Previews.stop_service(t1.id) end, fn -> Previews.start_service(t1.id) end])
    assert %{state: :ready} = Previews.info(t1.id)
  end

  test "retiring a project removes every track's service and marks the rows for cleanup", %{
    p: p,
    project: project,
    t1: t1,
    t2: t2
  } do
    parallel([fn -> Previews.start_service(t1.id) end, fn -> Previews.start_service(t2.id) end])
    assert :ok = Previews.retire_project(project.id)
    assert state(p).services == %{}
    assert %Row{cleanup: true, port: nil, sprite: nil} = Store.get(t1.id)
    assert %Row{cleanup: true, port: nil, sprite: nil} = Store.get(t2.id)
    assert {:error, {:conflict, "closed_track", _}} = Previews.start_service(t1.id)
  end

  test "a cleanup that cannot reach Sprites is saved and retried by the tick", %{p: p, t1: t1} do
    assert :ok = Previews.start_service(t1.id)
    put(p, :fail_stop, true)
    assert {:error, _} = Previews.stop_service(t1.id, :cleanup)
    assert %Row{cleanup: true, stop_pending: true, sprite: "s1"} = Store.get(t1.id)

    put(p, :fail_stop, false)
    Reconciler.tick()
    assert %Row{cleanup: true, stop_pending: false, sprite: nil, port: nil} = Store.get(t1.id)
    assert state(p).deletes == [service_id_of(t1.id, "s1")]
  end

  defp service_id_of(track_id, sprite), do: "#{sprite}/#{Store.get(track_id).service}"

  test "the destination refuses a machine that changed and restarts the service", %{p: p, t1: t1} do
    assert :ok = Previews.start_service(t1.id)
    assert {:ok, %Row{sprite: "s1"}} = Previews.destination(t1.id)

    put(p, :sandbox, "s2")
    assert {:error, {:unavailable, "preview_replaced", _}} = Previews.destination(t1.id)
    await(p, fn _ -> match?(%Row{sprite: "s2", state: :ready}, Store.get(t1.id)) end)
    assert {:ok, %Row{sprite: "s2"}} = Previews.destination(t1.id)
  end

  test "a pass reads the tracks and the projects once, however many previews there are", ctx do
    for id <- [ctx.t1.id, ctx.t2.id], do: Store.ensure(id)
    small = QueryCount.queries(&Reconciler.tick/0)

    for i <- 3..20 do
      track = insert_track(project: ctx.project, slug: "t#{i}", conversation_id: "c#{i}")
      Store.ensure(track.id)
    end

    {_result, queries} = QueryCount.count(&Reconciler.tick/0)

    assert length(queries) == small
    assert Enum.count(queries, &(&1 == "previews")) == 1
    assert Enum.count(queries, &(&1 == "tracks")) == 1
    assert Enum.count(queries, &(&1 == "projects")) == 1
  end

  test "reconciling one row asks nothing further about its track or its project", ctx do
    # The other half of the same statement, and the half that has teeth: the
    # pass hands each row what it needs, so a row reads neither. Asserted
    # here rather than through `tick/0`, which reconciles rows in tasks of
    # their own -- a query counter watching the caller would not see them,
    # and would go on passing if they came back.
    %Row{} = row = Store.ensure(ctx.t1.id)
    track = Repo.get!(Track, ctx.t1.id)
    project = Repo.get!(Ravix.Projects.Project, track.project_id)

    {_result, queries} = QueryCount.count(fn -> Reconciler.reconcile({row, track, project}) end)

    refute "tracks" in queries
    refute "projects" in queries
  end

  test "a preview whose track has gone is still cleaned up by the pass", %{p: p, t1: t1, t2: t2} do
    # The batched read must not lose the case the pass exists to answer. A
    # track absent from it is a track that has gone, and its service has to
    # go with it -- while the other project's rows carry on being reconciled.
    assert :ok = Previews.start_service(t1.id)
    assert :ok = Previews.start_service(t2.id)
    gone = Store.get(t1.id)

    Repo.update_all(from(t in Track, where: t.id == ^t1.id),
      set: [closed_at: DateTime.utc_now()]
    )

    Reconciler.tick()
    assert "s1/#{gone.service}" in state(p).deletes
    assert %Row{state: :ready} = Store.get(t2.id)
  end

  test "the decision table", %{t1: t1} do
    %Row{} = row = Store.ensure(t1.id)
    track = Repo.get!(Track, t1.id)
    project = Repo.get!(Ravix.Projects.Project, track.project_id)
    now = 1_000_000

    assert Reconciler.decide(row, track, project, now) == :leave
    assert Reconciler.decide(row, nil, project, now) == :leave
    assert Reconciler.decide(%{row | sprite: "s1"}, nil, project, now) == :cleanup

    assert Reconciler.decide(%{row | sprite: "s1", cleanup: true}, track, project, now) ==
             :cleanup

    assert Reconciler.decide(%{row | stop_pending: true}, track, project, now) == :stop

    running = %{row | desired: :running, last_activity: now, lease_until: now + 1}
    assert Reconciler.decide(running, track, project, now) == :ensure
    assert Reconciler.decide(%{running | lease_until: now}, track, project, now) == :leave

    assert Reconciler.decide(%{running | last_activity: now - 300_001}, track, project, now) ==
             :stop
  end
end
