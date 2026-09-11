defmodule Ravix.SpritesTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Ravix.Sprites
  alias Ravix.Sprites.Error
  alias Ravix.Sprites.Shapes.{Exec, Service}
  alias Ravix.SpritesFake, as: Fake

  @cfg Fake.config()

  # ── the frame decoder ──────────────────────────────────────────────────

  describe "decode_frames/1" do
    test "stdout and stderr stay separate, and the exit code arrives" do
      raw = Fake.frame(1, "out") <> Fake.frame(2, "err") <> <<3, 3>>
      assert Sprites.decode_frames(raw) == %Exec{stdout: "out", stderr: "err", code: 3}
    end

    test "a frame ends at the next id byte, so interleaved output reassembles in order" do
      raw = Fake.frame(1, "a") <> Fake.frame(2, "E") <> Fake.frame(1, "b") <> <<3, 0>>
      assert Sprites.decode_frames(raw) == %Exec{stdout: "ab", stderr: "E", code: 0}
    end

    test "no exit frame reads as success rather than as a crash" do
      # A truncated response is not the same as a failing command, and reporting
      # a non-zero code for one would put a red exit line under working output.
      assert Sprites.decode_frames(Fake.frame(1, "hello")).code == 0
    end

    test "an empty body is not an error" do
      assert Sprites.decode_frames(<<>>) == %Exec{stdout: "", stderr: "", code: 0}
    end

    test "bytes that are not UTF-8 are replaced rather than passed to the page" do
      assert %Exec{stdout: "a�b"} = Sprites.decode_frames(Fake.frame(1, <<?a, 0xFF, ?b>>))
    end
  end

  # ── the confinement, which is the whole security of the terminal ───────

  @root "/home/sprite/work/kyoto"

  describe "resolve_cwd/2" do
    test "a relative path resolves inside the track's worktree" do
      assert Sprites.resolve_cwd(@root, "src") == "#{@root}/src"
      assert Sprites.resolve_cwd(@root, "src/lib/..") == "#{@root}/src"
      assert Sprites.resolve_cwd(@root, nil) == @root
    end

    test "escaping upward snaps back to the root instead of leaving the worktree" do
      # Without this the terminal is a way around the one rule the agent is
      # told three times to follow, including into another track's directory.
      assert Sprites.resolve_cwd(@root, "..") == @root
      assert Sprites.resolve_cwd(@root, "../../..") == @root
      assert Sprites.resolve_cwd(@root, "/etc") == @root
      assert Sprites.resolve_cwd(@root, "/home/sprite/work/other") == @root
      assert Sprites.resolve_cwd(@root, "src/../../../../etc/passwd") == @root
    end

    test "a sibling whose name merely starts with the root is not inside it" do
      # `/home/sprite/work/kyoto-2` is another track. String-prefix matching
      # without the separator would hand it over.
      assert Sprites.resolve_cwd(@root, "/home/sprite/work/kyoto-2") == @root
    end
  end

  test "quoting survives the characters a shell would otherwise act on" do
    assert Sprites.shq("plain") == "'plain'"
    assert Sprites.shq("it's") == "'it'\\''s'"
    assert Sprites.shq("a; rm -rf /") == "'a; rm -rf /'"
  end

  # ── services ───────────────────────────────────────────────────────────

  test "managed services use private ports, bounded NDJSON operations, and expiring tasks" do
    Fake.install(fn conn, call ->
      assert call.authorization == "Bearer provider-token"

      cond do
        String.ends_with?(call.path, "/exec") ->
          send_resp(conn, 200, <<3, 0>>)

        call.method == "GET" ->
          Req.Test.json(conn, %{name: "sy-test", state: %{status: "running"}})

        true ->
          send_resp(conn, 200, ~s({"type":"started"}\n{"type":"complete"}\n))
      end
    end)

    assert {:ok, ~s({"type":"started"}\n{"type":"complete"}\n)} =
             Sprites.define_service(
               @cfg,
               "sprite",
               "sy-test",
               "/work/one/app",
               "npm start",
               20_123
             )

    assert {:ok, _} = Sprites.service_action(@cfg, "sprite", "sy-test", :stop)
    assert {:ok, _} = Sprites.service_action(@cfg, "sprite", "sy-test", :delete)
    assert :ok = Sprites.activity(@cfg, "sprite", "sy-test")
    assert :ok = Sprites.activity(@cfg, "sprite", "sy-test", :release)
    assert {:ok, ""} = Sprites.service_logs(@cfg, "sprite", "sy-test")

    assert {:ok, %Service{name: "sy-test", status: "running"}} =
             Sprites.service(@cfg, "sprite", "sy-test")

    [define, stop, delete, hold, release, logs, get] = Fake.calls()

    assert define.method == "PUT"
    assert define.path == "/v1/sprites/sprite/services/sy-test"
    assert define.query =~ "duration=1s"

    assert define.body == %{
             "cmd" => "sh",
             "args" => ["-lc", "npm start"],
             "dir" => "/work/one/app",
             "env" => %{"PORT" => "20123", "HOST" => "127.0.0.1"},
             "needs" => []
           }

    assert stop.method == "POST"
    assert stop.path =~ "/stop"
    assert stop.query =~ "duration=1s"
    assert delete.method == "DELETE"
    assert delete.path == "/v1/sprites/sprite/services/sy-test"
    assert ~s({"expire":"2m"}) in hold.argv
    assert "PUT" in hold.argv
    assert "DELETE" in release.argv
    refute ~s({"expire":"2m"}) in release.argv
    assert logs.argv == ["tail", "-c", "32000", "/.sprite/logs/services/sy-test.log"]
    assert get.method == "GET"
  end

  test "stopping an already exited service is idempotent with the live Sprites conflict response" do
    Fake.install(fn conn, _call -> send_resp(conn, 409, "service is not running\n") end)

    assert {:ok, ""} = Sprites.service_action(@cfg, "sprite", "sy-test", :stop)
    assert {:ok, ""} = Sprites.service_action(@cfg, "sprite", "sy-test", :stop)

    assert {:error, %Error{status: 409}} =
             Sprites.service_action(@cfg, "sprite", "sy-test", :start)
  end

  test "unrelated stop conflicts remain failures" do
    Fake.install(fn conn, _call -> send_resp(conn, 409, "service operation in progress") end)

    assert {:error, %Error{status: 409}} =
             Sprites.service_action(@cfg, "sprite", "sy-test", :stop)
  end

  test "a service that does not exist is nil, and deleting or stopping it is fine" do
    Fake.install(fn conn, _call -> send_resp(conn, 404, "missing") end)

    assert {:ok, nil} = Sprites.service(@cfg, "sprite", "sy-test")
    assert {:ok, "missing"} = Sprites.service_action(@cfg, "sprite", "sy-test", :delete)
    assert {:ok, "missing"} = Sprites.service_action(@cfg, "sprite", "sy-test", :stop)

    assert {:error, %Error{status: 404}} =
             Sprites.service_action(@cfg, "sprite", "sy-test", :start)
  end

  test "a sprite whose API has no expiring tasks answers 501 for the lease, and release never fails on it" do
    Fake.install(fn conn, _call -> Fake.exec_response(conn, "", "no such route", 22) end)

    assert {:error, %Error{status: 501}} = Sprites.activity(@cfg, "sprite", "sy-test")
    assert :ok = Sprites.activity(@cfg, "sprite", "sy-test", :release)
  end

  test "service output is bounded to its last 32,000 bytes" do
    long = String.duplicate("x", 40_000) <> "END"
    Fake.install(fn conn, _call -> send_resp(conn, 200, long) end)

    assert {:ok, out} = Sprites.define_service(@cfg, "sprite", "sy", "/w", "npm start", 1)
    assert byte_size(out) == 32_000
    assert String.ends_with?(out, "END")
  end

  # ── exec and shell ─────────────────────────────────────────────────────

  test "exec sends the argv as repeated cmd parameters and decodes the frames" do
    Fake.install(fn conn, call ->
      assert call.method == "POST"
      assert call.path == "/v1/sprites/my%20sprite/exec"
      assert call.argv == ["git", "status", "--short"]
      Fake.exec_response(conn, "M file\n", "warning\n", 1)
    end)

    assert {:ok, %{stdout: "M file\n", stderr: "warning\n", code: 1}} =
             Sprites.exec(@cfg, "my sprite", ["git", "status", "--short"], 30)
  end

  test "an unreachable machine is a 404 with the message the panel shows" do
    Fake.install(fn conn, _call -> send_resp(conn, 404, "no sprite") end)

    assert {:error, %Error{status: 404, message: message}} =
             Sprites.exec(@cfg, "gone", ["true"], 5)

    assert message =~ "not reachable over Sprites"
  end

  test "other Sprites failures carry the status and the first 200 bytes of the body" do
    Fake.install(fn conn, _call -> send_resp(conn, 500, String.duplicate("boom ", 100)) end)

    assert {:error, %Error{status: 500, message: message}} = Sprites.exec(@cfg, "s", ["true"], 5)
    assert String.starts_with?(message, "Sprites said 500. boom ")
    assert byte_size(message) <= byte_size("Sprites said 500. ") + 200
  end

  test "a timeout and a refused connection are 502s that say which" do
    Fake.install(fn conn, _call -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %Error{status: 502, message: "The machine did not answer in time."}} =
             Sprites.exec(@cfg, "s", ["true"], 5)

    Fake.install(fn conn, _call -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, %Error{status: 502, message: "Could not reach the machine."}} =
             Sprites.exec(@cfg, "s", ["true"], 5)
  end

  test "shell runs under sh in the cwd and reports where it ended up" do
    Fake.install(fn conn, call ->
      assert ["sh", "-lc", script] = call.argv

      assert String.starts_with?(
               script,
               "cd '/home/sprite/work/it'\\''s' 2>/dev/null || cd /home/sprite; { cd src && ls\n }"
             )

      Fake.exec_response(conn, "a.ex\nb.ex\n\n__ravix_cwd__/home/sprite/work/it's/src\n", "", 0)
    end)

    assert {:ok, %Exec{stdout: "a.ex\nb.ex\n", stderr: "", code: 0}, "/home/sprite/work/it's/src"} =
             Sprites.shell(@cfg, "s", "cd src && ls", "/home/sprite/work/it's", 30)
  end

  test "shell keeps the cwd it was given when the marker never printed" do
    Fake.install(fn conn, _call -> Fake.exec_response(conn, "partial", "killed", 137) end)

    assert {:ok, %Exec{stdout: "partial", stderr: "killed", code: 137}, "/w"} =
             Sprites.shell(@cfg, "s", "sleep 100", "/w", 1)
  end

  test "reachable? is true only for a zero exit, and false for any failure" do
    Fake.install(fn conn, _call -> send_resp(conn, 200, <<3, 0>>) end)
    assert Sprites.reachable?(@cfg, "s")

    Fake.install(fn conn, _call -> send_resp(conn, 404, "") end)
    refute Sprites.reachable?(@cfg, "s")
  end

  test "without a token every call says so instead of trying" do
    assert {:error, :unconfigured} = Sprites.exec(nil, "s", ["true"], 5)
    assert {:error, :unconfigured} = Sprites.shell(nil, "s", "ls", "/", 5)
    assert {:error, :unconfigured} = Sprites.service(nil, "s", "sy")
    assert {:error, :unconfigured} = Sprites.define_service(nil, "s", "sy", "/w", "npm start", 1)
    assert {:error, :unconfigured} = Sprites.service_action(nil, "s", "sy", :stop)
    assert {:error, :unconfigured} = Sprites.service_logs(nil, "s", "sy")
    assert {:error, :unconfigured} = Sprites.activity(nil, "s", "sy")
    refute Sprites.reachable?(nil, "s")
  end
end
