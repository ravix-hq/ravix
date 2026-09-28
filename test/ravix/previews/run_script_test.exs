defmodule Ravix.Previews.RunScriptTest do
  use Ravix.DataCase, async: true, group: :preview_ports
  use Mimic
  import Ravix.PreviewsFixture

  alias Ravix.Previews
  alias Ravix.Previews.{Config, Lifecycle, Reconciler, Row, Store}
  alias Ravix.Sprites.Shapes

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
             :observe

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

    assert {:ok, %{state: :stopped, logs: logs}} = Previews.stop(ctx.owner, ctx.track.id)
    assert logs =~ "[warning] Stop command:"
    assert logs =~ "status 7"
    assert state(ctx.provider).services["#{row.sprite}/#{row.service}"] == "stopped"
    refute Store.get(ctx.track.id).stop_pending
    assert "#{row.sprite}/#{row.service}/release" in state(ctx.provider).holds
  end

  for {code, expected} <- [{0, :stopped}, {17, :failed}] do
    test "a plain process that exits #{code} after running stays #{expected} until explicitly run",
         ctx do
      assert {:ok, _} =
               Previews.save_config(ctx.owner, ctx.track.id, %{directory: ".", command: "worker"})

      assert {:ok, %{state: :running}} = Previews.run(ctx.owner, ctx.track.id)
      row = Store.get(ctx.track.id)
      put(ctx.provider, :exit_code, unquote(code))
      put(ctx.provider, :services, %{"#{row.sprite}/#{row.service}" => "stopped"})
      creates = state(ctx.provider).creates
      assert :ok = Reconciler.reconcile({row, ctx.track, ctx.project})

      assert %{state: unquote(expected), desired: :stopped, lease_until: 0, logs: logs} =
               Store.get(ctx.track.id)

      assert logs =~ "command not found"
      before = state(ctx.provider)
      assert :ok = Reconciler.reconcile({Store.get(ctx.track.id), ctx.track, ctx.project})
      assert state(ctx.provider) == before
      assert state(ctx.provider).creates == creates
      assert "#{row.sprite}/#{row.service}/release" in state(ctx.provider).holds
      put(ctx.provider, :exit_code, nil)
      assert {:ok, %{state: :running}} = Previews.run(ctx.owner, ctx.track.id)
      assert state(ctx.provider).creates == creates + 1
    end
  end

  test "even one provider restart after running is a failure, without another start", ctx do
    assert {:ok, _} =
             Previews.save_config(ctx.owner, ctx.track.id, %{directory: ".", command: "worker"})

    assert {:ok, %{state: :running}} = Previews.run(ctx.owner, ctx.track.id)
    put(ctx.provider, :crash, 1)
    assert :ok = Reconciler.reconcile({Store.get(ctx.track.id), ctx.track, ctx.project})
    assert %{state: :failed, desired: :stopped, error: error} = Store.get(ctx.track.id)
    assert error =~ "provider restarted"
    assert state(ctx.provider).creates == 1
  end

  test "a delayed observation cannot replace a newer stop with a failed exit", ctx do
    assert {:ok, _} =
             Previews.save_config(ctx.owner, ctx.track.id, %{directory: ".", command: "worker"})

    assert {:ok, _} = Previews.run(ctx.owner, ctx.track.id)
    row = Store.get(ctx.track.id)
    before = state(ctx.provider).stops

    expect(Ravix.Sprites, :service, fn _, _, _ ->
      Store.update(ctx.track.id,
        generation: row.generation + 1,
        state: :stopped,
        desired: :stopped
      )

      {:ok, Shapes.service(%{"state" => %{"status" => "failed", "exit_code" => 3}})}
    end)

    assert :ok = Reconciler.reconcile({row, ctx.track, ctx.project})
    assert %{state: :stopped, error: nil} = Store.get(ctx.track.id)
    assert state(ctx.provider).stops == before
  end

  test "display state and keep-awake use the applied script while defaults change", ctx do
    assert {:ok, _} =
             Previews.set_defaults(ctx.owner, ctx.project.id, %{directory: ".", command: "worker"})

    assert {:ok, %{state: :running, keeps_awake: true}} = Previews.run(ctx.owner, ctx.track.id)

    Store.set_defaults(ctx.project.id, %Config{
      directory: ".",
      command: "http",
      readiness_path: "/"
    })

    assert %{state: :running, keeps_awake: true, url: nil} = Lifecycle.info(ctx.track.id)
  end

  test "HTTP display remains ready while the saved default changes to plain", ctx do
    assert {:ok, _} =
             Previews.set_defaults(ctx.owner, ctx.project.id, %{
               directory: ".",
               command: "http",
               readiness_path: "/"
             })

    assert {:ok, %{state: :ready, keeps_awake: false}} = Previews.run(ctx.owner, ctx.track.id)
    Store.set_defaults(ctx.project.id, %Config{directory: ".", command: "worker"})
    assert %{state: :ready, keeps_awake: false, url: url} = Lifecycle.info(ctx.track.id)
    assert is_binary(url)
  end

  for code <- [0, 9] do
    test "a plain command exiting #{code} before its first running probe settles immediately",
         ctx do
      assert {:ok, _} =
               Previews.save_config(ctx.owner, ctx.track.id, %{directory: ".", command: "worker"})

      stub(Ravix.Sprites, :service, fn _, _, _ ->
        service =
          if state(ctx.provider).creates > 0,
            do:
              Shapes.service(%{
                "state" => %{"status" => "stopped", "exit_code" => unquote(code)}
              })

        {:ok, service}
      end)

      assert {:ok, info} = Previews.run(ctx.owner, ctx.track.id)
      assert info.state == if(unquote(code) == 0, do: :stopped, else: :failed)
      assert Store.get(ctx.track.id).desired == :stopped
    end
  end

  for mode <- [:restart, :cleanup] do
    test "a failing stop command does not abort #{mode}", ctx do
      assert {:ok, _} =
               Previews.save_config(ctx.owner, ctx.track.id, %{
                 directory: ".",
                 command: "worker",
                 stop_command: "bad-stop"
               })

      assert {:ok, _} = Previews.run(ctx.owner, ctx.track.id)
      row = Store.get(ctx.track.id)

      stub(Ravix.Sprites, :exec, fn _, _, ["sh", "-lc", script], _ ->
        {:ok, %{code: if(script =~ "bad-stop", do: 7, else: 0), stdout: "", stderr: ""}}
      end)

      if unquote(mode) == :restart do
        assert {:ok, %{state: :running, logs: logs}} =
                 Previews.run(ctx.owner, ctx.track.id, :restart)

        assert logs =~ "[warning] Stop command:"
        assert state(ctx.provider).creates == 2
      else
        assert :ok = Lifecycle.stop_service(ctx.track.id, :cleanup)

        assert %{sprite: nil, port: nil, stop_pending: false, logs: logs} =
                 Store.get(ctx.track.id)

        assert logs =~ "[warning] Stop command:"
        assert "#{row.sprite}/#{row.service}/release" in state(ctx.provider).holds
      end

      assert "#{row.sprite}/#{row.service}" in state(ctx.provider).deletes
    end
  end
end
