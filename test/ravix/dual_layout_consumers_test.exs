defmodule Ravix.DualLayoutConsumersTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Fountain.FakeTransport
  alias Ravix.{MachineCache, Projects, SpritesFake, Terminal, Tracks, Vitals}
  alias Ravix.Tracks.Track

  setup do
    owner = insert_user()
    project = insert_project(user: owner)

    tracks =
      for id <- ["one", "two"],
          do:
            insert_track(
              project: project,
              sandbox_layout: :dedicated,
              sandbox_id: id,
              workdir: "/workspace/#{id}"
            )

    %{owner: owner, project: project, tracks: tracks}
  end

  test "terminal, Vitals, file, listing and diff stay on the selected dedicated disk", ctx do
    stub(Ravix.Config, :sprites, fn -> SpritesFake.config() end)

    for track <- ctx.tracks do
      id = track.sandbox_id

      client =
        FakeTransport.client([
          {%{method: "GET", path: "/api/sandboxes/#{id}"},
           {200, [], %{data: %{id: id, sprite_name: "sprite-#{id}"}}}},
          {%{
             method: "GET",
             path: "/api/sandboxes/#{id}/file",
             query: %{path: "#{track.workdir}/a.txt"}
           },
           {200, [], %{data: %{path: "#{track.workdir}/a.txt", content: id, encoding: "utf-8"}}}},
          {%{method: "GET", path: "/api/sandboxes/#{id}/files"},
           {200, [], %{data: %{path: track.workdir, entries: [], truncated: false}}}},
          {%{method: "GET", path: "/api/sandboxes/#{id}/diff"},
           {200, [], %{data: %{path: track.workdir, diff: "", truncated: false}}}}
        ])

      stub(Ravix.Fountain, :client, fn -> client end)

      # The diff's untracked read asks whether the sprite is running first.
      untracked =
        Jason.encode!(%{
          available: true,
          diff: "diff --git a/#{id}.txt b/#{id}.txt\nnew file mode 100644\n",
          large: [],
          truncated: false
        })

      SpritesFake.install(fn conn, call ->
        if call.method == "GET" do
          assert call.path == "/v1/sprites/sprite-#{id}"
          Plug.Conn.send_resp(conn, 200, ~s({"status":"running"}))
        else
          assert call.path == "/v1/sprites/sprite-#{id}/exec"
          assert ["sh", "-lc", script] = call.argv
          assert script =~ track.workdir

          cond do
            script =~ "cpu.max" ->
              SpritesFake.exec_response(conn, "nproc=#{if id == "one", do: 1, else: 2}\n")

            script =~ "b64decode" ->
              SpritesFake.exec_response(conn, "#{untracked}\n__ravix_cwd__#{track.workdir}\n")

            true ->
              SpritesFake.exec_response(conn, "#{id}\n__ravix_cwd__#{track.workdir}\n")
          end
        end
      end)

      assert {:ok, %{stdout: output}} = Terminal.exec(ctx.owner, track.id, %{command: "pwd"})
      assert output == id
      assert {:ok, %{readings: %{cpu_cores: cores}}} = Vitals.report(ctx.owner, track.id)
      assert cores == if(id == "one", do: 1, else: 2)
      assert {:ok, %{content: ^id}} = Tracks.file(ctx.owner, track.id, "a.txt")
      assert {:ok, %{entries: []}} = Tracks.files(ctx.owner, track.id, nil)

      assert {:ok, %{changes: [%{path: path, status: :untracked}]}} =
               Tracks.diff(ctx.owner, track.id)

      assert path == "#{id}.txt"
      refute Enum.any?(FakeTransport.calls(client), &(&1.path == "/api/conversations"))
    end
  end

  test "track membership never grants the sibling disk, and revocation denies all readers", ctx do
    [one, two] = ctx.tracks
    member = insert_user()
    membership = insert_track_member(one, member)
    client = FakeTransport.client([])
    stub(Ravix.Fountain, :client, fn -> client end)
    assert {:ok, %{sandbox_id: "one"}} = Tracks.machine_for_track(member, one.id)

    for reader <- [
          &Tracks.file(&1, &2, "a"),
          &Tracks.diff/2,
          &Terminal.exec(&1, &2, %{command: "pwd"}),
          &Vitals.report/2
        ] do
      assert {:error, :not_found} = reader.(member, two.id)
    end

    Repo.delete!(membership)
    assert {:error, :not_found} = Tracks.machine_for_track(member, one.id)
    assert {:error, :not_found} = Tracks.file(member, one.id, "a")
    assert {:error, :not_found} = Terminal.exec(member, one.id, %{command: "pwd"})
    assert {:error, :not_found} = Vitals.report(member, one.id)
    assert FakeTransport.calls(client) == []
  end

  test "an unresolved dedicated disk never falls back to the project", ctx do
    [track | _] = ctx.tracks
    Repo.update!(Ecto.Changeset.change(track, sandbox_id: nil))
    stub(Ravix.Config, :sprites, fn -> SpritesFake.config() end)
    client = FakeTransport.client([])
    stub(Ravix.Fountain, :client, fn -> client end)
    assert {:error, {:conflict, "no_machine", _}} = Tracks.file(ctx.owner, track.id, "a")

    assert {:error, {:conflict, "no_machine", _}} =
             Terminal.exec(ctx.owner, track.id, %{command: "pwd"})

    assert {:ok, %{why: :no_machine}} = Vitals.report(ctx.owner, track.id)
    assert FakeTransport.calls(client) == []
  end

  test "legacy discovery excludes dedicated disks and unresolved dedicated threads", ctx do
    [one, two] = ctx.tracks
    Repo.update!(Ecto.Changeset.change(two, sandbox_id: nil, conversation_id: "dedicated-thread"))

    rows = [
      %{id: "shared", sandbox_id: "shared-disk", status: "idle", inserted_at: "2026-01-01"},
      %{id: "dedicated", sandbox_id: one.sandbox_id, status: "idle", inserted_at: "2026-02-01"},
      %{
        id: "dedicated-thread",
        sandbox_id: "unrecorded",
        status: "idle",
        inserted_at: "2026-03-01"
      }
    ]

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: rows}}}
      ])

    stub(Ravix.Fountain, :client, fn -> client end)
    assert {:ok, %{sandbox_id: "shared-disk"}} = MachineCache.machine_of(client, ctx.project)
    assert %{sandbox_id: "shared-disk"} = Projects.Machine.state(ctx.project)
  end

  test "project rebuild, runtime switch and delete refuse dedicated ownership; track close requires confirmation",
       ctx do
    client = FakeTransport.client([])
    stub(Ravix.Fountain, :client, fn -> client end)

    for operation <- [&Projects.rebuild/2, &Projects.destroy/2] do
      assert {:error, {:conflict, "dedicated_lifecycle_pending", _}} =
               operation.(ctx.owner, ctx.project.id)
    end

    assert {:error, {:conflict, "dedicated_lifecycle_pending", _}} =
             Projects.Machine.rebuild(%{ctx.project | runtime: "codex"}, client)

    [track | _] = ctx.tracks

    assert {:error, {:conflict, "confirm_machine_deletion", _}} =
             Tracks.close(ctx.owner, track.id)

    assert :ok = Tracks.close(ctx.owner, track.id, force: true)
    assert Repo.get!(Track, track.id).sandbox_state == :closing

    shared = insert_track(project: ctx.project)
    assert :ok = Tracks.close_all_for_rebuild(ctx.project, :rebuild)
    assert Repo.get!(Track, shared.id).closed_at
    for dedicated <- ctx.tracks, do: assert(is_nil(Repo.get!(Track, dedicated.id).closed_at))
    assert FakeTransport.calls(client) == []
  end
end
