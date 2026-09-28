defmodule Ravix.Previews.RunScriptTest do
  use Ravix.DataCase, async: true, group: :preview_ports
  use Mimic
  import Ravix.PreviewsFixture

  alias Ravix.Previews
  alias Ravix.Previews.{Config, Lifecycle, Reconciler, Row, Store}

  setup do
    provider = start_provider()
    stub_provider(provider)
    owner = insert_user()
    member = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project)
    insert_track_member(track, member)
    %{provider: provider, owner: owner, member: member, project: project, track: track}
  end

  test "legacy preview defaults become the run script in place, with owner-only writes", ctx do
    insert_preview_default(ctx.project,
      config: %{directory: ".", command: "npm start", readinessPath: "/health"}
    )

    assert {:ok, %Config{readiness_path: "/health", stop_command: nil}} =
             Previews.defaults(ctx.owner, ctx.project.id)

    attrs = %{directory: "apps/worker", command: "worker", stop_command: "worker-stop"}
    assert {:error, :not_found} = Previews.set_defaults(ctx.member, ctx.project.id, attrs)

    assert {:ok, %Config{readiness_path: nil, stop_command: "worker-stop"} = saved} =
             Previews.set_defaults(ctx.owner, ctx.project.id, attrs)

    assert {:ok, ^saved} = Previews.defaults(ctx.owner, ctx.project.id)

    assert {:ok, %{config: ^saved, override: nil, url: nil}} =
             Previews.status(ctx.member, ctx.track.id)

    assert Repo.aggregate(Ravix.Previews.PreviewDefault, :count) == 1
  end

  test "track members run, restart, read output and stop a plain process without HTTP probing",
       ctx do
    assert {:ok, _} =
             Previews.set_defaults(ctx.owner, ctx.project.id, %{directory: ".", command: "worker"})

    stub(Ravix.Config, :previews, fn -> nil end)
    reject(&Lifecycle.ready?/2)

    assert {:ok, %{state: :running, url: nil, open_url: nil, logs: "startup logs"}} =
             Previews.run(ctx.member, ctx.track.id)

    row = Store.get(ctx.track.id)
    assert row.port != nil

    assert {:error, {:conflict, "no_preview", _}} =
             Previews.open_ticket(ctx.member, ctx.track.id, "session")

    assert {:ok, %{state: :running}} = Previews.run(ctx.member, ctx.track.id, :restart)
    assert state(ctx.provider).creates == 2
    assert {:ok, %{logs: "Error: command not found"}} = Previews.logs(ctx.member, ctx.track.id)
    assert {:ok, %{state: :stopped}} = Previews.stop(ctx.member, ctx.track.id)
    assert state(ctx.provider).services["#{row.sprite}/#{row.service}"] == "stopped"
    assert Enum.all?(state(ctx.provider).execs, fn ["sh", "-lc", script] -> script =~ "ss -H" end)

    stranger = insert_user()
    insert_project(user: stranger)

    for action <- [&Previews.run/2, &Previews.stop/2, &Previews.status/2] do
      assert {:error, :not_found} = action.(stranger, ctx.track.id)
    end

    assert {:error, :not_found} = Previews.run(stranger, ctx.track.id, :restart)
  end

  test "plain processes survive the HTTP idle timeout and failed commands retain diagnostics",
       ctx do
    assert {:ok, _} =
             Previews.save_config(ctx.owner, ctx.track.id, %{directory: ".", command: "worker"})

    assert {:ok, %{state: :running}} = Previews.run(ctx.owner, ctx.track.id)
    advance(ctx.provider, Previews.idle_ms() + 1)

    assert Reconciler.decide(Store.get(ctx.track.id), ctx.track, ctx.project, now(ctx.provider)) ==
             :ensure

    put(ctx.provider, :crash, 3)
    assert {:ok, %{state: :failed, logs: logs}} = Previews.run(ctx.owner, ctx.track.id, :restart)
    assert logs =~ "command not found"
    assert Store.get(ctx.track.id).desired == :stopped
  end

  test "stop and restart use the applied stop command, even after configuration changes", ctx do
    old = %{directory: "apps/old", command: "worker", stop_command: "stop-old"}
    assert {:ok, _} = Previews.save_config(ctx.owner, ctx.track.id, old)
    assert {:ok, _} = Previews.run(ctx.owner, ctx.track.id)
    row = Store.get(ctx.track.id)
    assert Row.applied(row).stop_command == "stop-old"
    assert {:ok, _} = Previews.run(ctx.owner, ctx.track.id, :restart)

    assert {:ok, _} =
             Previews.save_config(ctx.owner, ctx.track.id, %{old | stop_command: "stop-new"})

    stops =
      for ["sh", "-lc", script] <- state(ctx.provider).execs, script =~ "stop-old", do: script

    assert length(stops) == 2

    assert Enum.all?(
             stops,
             &(&1 =~ ctx.track.workdir <> "/apps/old" and &1 =~ "PORT='#{row.port}'")
           )

    refute Enum.any?(state(ctx.provider).execs, &(inspect(&1) =~ "stop-new"))
  end

  test "a failing custom shutdown still stops the service group and reports its failure", ctx do
    assert {:ok, _} =
             Previews.save_config(ctx.owner, ctx.track.id, %{
               directory: ".",
               command: "worker",
               stop_command: "bad-stop"
             })

    assert {:ok, _} = Previews.run(ctx.owner, ctx.track.id)
    row = Store.get(ctx.track.id)

    expect(Ravix.Sprites, :exec, fn _, _, ["sh", "-lc", script], 15 ->
      assert script =~ "bad-stop"
      {:ok, %{code: 7, stdout: "", stderr: "failed"}}
    end)

    assert {:error, {:unavailable, message}} = Previews.stop(ctx.owner, ctx.track.id)
    assert message =~ "status 7"
    assert state(ctx.provider).services["#{row.sprite}/#{row.service}"] == "stopped"
    assert Store.get(ctx.track.id).stop_pending
    assert {:ok, %{state: :stopped}} = Previews.stop(ctx.owner, ctx.track.id)
    refute Store.get(ctx.track.id).stop_pending
  end
end
