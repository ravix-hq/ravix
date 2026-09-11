defmodule Ravix.TerminalTest do
  use Ravix.DataCase, async: true

  import Mimic
  import Plug.Conn

  alias Ravix.Fountain.FakeTransport
  alias Ravix.SpritesFake
  alias Ravix.Terminal

  @sprites SpritesFake.config()

  setup_all do
    Ravix.TracksBoot.ensure_running()
    :ok
  end

  setup do
    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project, slug: "kyoto")
    {:ok, owner: owner, project: project, track: track}
  end

  # A Fountain whose project has one machine, on a sprite or not.
  defp fountain(project, sprite) do
    sandbox = %{id: "sb-1", sprite_name: sprite}

    client =
      FakeTransport.client(
        [
          {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
           {200, [],
            %{
              data: [
                %{
                  id: "c1",
                  sandbox_id: "sb-1",
                  status: "idle",
                  inserted_at: "2026-09-09T00:00:00Z"
                }
              ]
            }}},
          {%{method: "GET", path: "/api/sandboxes/sb-1"}, {200, [], %{data: sandbox}}}
        ],
        verify: false
      )

    stub(Ravix.Fountain, :client, fn -> client end)
    client
  end

  defp no_machine(project) do
    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
         {200, [], %{data: []}}}
      ])

    stub(Ravix.Fountain, :client, fn -> client end)
  end

  describe "exec/3" do
    test "runs the command in the worktree over Sprites and reports where the shell ended", ctx do
      stub(Ravix.Config, :sprites, fn -> @sprites end)
      fountain(ctx.project, "sprite-7")

      SpritesFake.install(fn conn, call ->
        assert conn.request_path == "/v1/sprites/sprite-7/exec"
        assert ["sh", "-lc", script] = call.argv
        assert script =~ "cd '/home/sprite/work/kyoto/src'"
        assert script =~ "ls -la"

        SpritesFake.exec_response(
          conn,
          "app.ts\n\n__ravix_cwd__/home/sprite/work/kyoto/src/lib\n",
          "",
          0
        )
      end)

      assert {:ok, result} =
               Terminal.exec(ctx.owner, ctx.track.id, %{"command" => "ls -la", "cwd" => "src"})

      assert result.stdout == "app.ts\n"
      assert result.code == 0
      assert result.cwd == "/home/sprite/work/kyoto/src/lib"
      refute result.timed_out
      assert is_integer(result.duration_ms)
    end

    test "a directory the shell walked out to snaps back inside the worktree", ctx do
      stub(Ravix.Config, :sprites, fn -> @sprites end)
      fountain(ctx.project, "sprite-7")

      SpritesFake.install(fn conn, _call ->
        SpritesFake.exec_response(conn, "\n__ravix_cwd__/home/sprite\n", "", 0)
      end)

      assert {:ok, %{cwd: "/home/sprite/work/kyoto"}} =
               Terminal.exec(ctx.owner, ctx.track.id, %{
                 command: "cd /home/sprite",
                 cwd: "../../.."
               })
    end

    test "exit 124 is a timeout, and the timeout is clamped to the ceiling", ctx do
      stub(Ravix.Config, :sprites, fn -> @sprites end)
      fountain(ctx.project, "sprite-7")

      SpritesFake.install(fn conn, call ->
        assert ["sh", "-lc", _] = call.argv
        SpritesFake.exec_response(conn, "", "", 124)
      end)

      assert {:ok, %{timed_out: true, code: 124}} =
               Terminal.exec(ctx.owner, ctx.track.id, %{command: "sleep 999", timeout_sec: 9_999})
    end

    test "no token, no command, no machine and no sprite are told apart", ctx do
      stub(Ravix.Config, :sprites, fn -> nil end)

      assert {:error, {:unavailable, "no_exec", _}} =
               Terminal.exec(ctx.owner, ctx.track.id, %{command: "ls"})

      stub(Ravix.Config, :sprites, fn -> @sprites end)

      assert {:error, %Ecto.Changeset{errors: [command: {"Type a command.", _}]}} =
               Terminal.exec(ctx.owner, ctx.track.id, %{command: "  "})

      no_machine(ctx.project)

      assert {:error, {:conflict, "no_machine", _}} =
               Terminal.exec(ctx.owner, ctx.track.id, %{command: "ls"})

      fountain(ctx.project, nil)

      assert {:error, {:unavailable, "no_exec", _}} =
               Terminal.exec(ctx.owner, ctx.track.id, %{command: "ls"})
    end

    test "a machine Sprites cannot reach is the sprite's error, not a crash", ctx do
      stub(Ravix.Config, :sprites, fn -> @sprites end)
      fountain(ctx.project, "sprite-7")
      SpritesFake.install(fn conn, _call -> send_resp(conn, 404, "gone") end)

      assert {:error, %Ravix.Sprites.Error{status: 404}} =
               Terminal.exec(ctx.owner, ctx.track.id, %{command: "ls"})
    end

    test "a stranger is told the track does not exist", ctx do
      stub(Ravix.Config, :sprites, fn -> @sprites end)
      assert {:error, :not_found} = Terminal.exec(insert_user(), ctx.track.id, %{command: "ls"})
    end
  end

  describe "status/2" do
    test "the four answers, in the order the panel tells them apart", ctx do
      stub(Ravix.Config, :sprites, fn -> nil end)

      assert {:ok, %{available: false, why: :no_token, cwd: "/home/sprite/work/kyoto"}} =
               Terminal.status(ctx.owner, ctx.track.id)

      stub(Ravix.Config, :sprites, fn -> @sprites end)
      no_machine(ctx.project)

      assert {:ok, %{available: false, why: :no_machine}} =
               Terminal.status(ctx.owner, ctx.track.id)

      fountain(ctx.project, nil)

      assert {:ok, %{available: false, why: :no_sprite}} =
               Terminal.status(ctx.owner, ctx.track.id)

      fountain(ctx.project, "sprite-7")
      SpritesFake.install(fn conn, _call -> send_resp(conn, 404, "asleep") end)

      assert {:ok, %{available: false, why: :unreachable}} =
               Terminal.status(ctx.owner, ctx.track.id)

      SpritesFake.install(fn conn, call ->
        assert call.argv == ["true"]
        SpritesFake.exec_response(conn, "", "", 0)
      end)

      assert {:ok, %{available: true, why: nil}} = Terminal.status(ctx.owner, ctx.track.id)
    end
  end
end
