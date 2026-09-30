defmodule Ravix.GitStatusTest do
  # The Checks tab's Git status and writes, with the machine stubbed at the
  # provider boundary: Sprites' exec API. The stub runs the script it is sent
  # with `sh` against a real repository and a real bare remote in a temporary
  # directory, so the counts and the failures are Git's own rather than text
  # this test made up to agree with the parser.
  use Ravix.DataCase, async: true

  import Mimic

  alias Ravix.Fountain.FakeTransport
  alias Ravix.SpritesFake
  alias Ravix.Tracks
  alias Ravix.Tracks.Attribution
  alias Ravix.Tracks.Git

  @moduletag :tmp_dir

  setup_all do
    Ravix.TracksBoot.ensure_running()
    :ok
  end

  setup %{tmp_dir: tmp} do
    remote = Path.join(tmp, "remote.git")
    work = Path.join(tmp, "work")
    git!(tmp, ["init", "-q", "--bare", "-b", "main", remote])
    git!(tmp, ["clone", "-q", remote, work])
    git!(work, ["config", "user.name", "Fixture"])
    git!(work, ["config", "user.email", "fixture@example.test"])
    File.write!(Path.join(work, "README"), "one\n")
    git!(work, ["add", "README"])
    git!(work, ["commit", "-q", "-m", "first"])
    git!(work, ["push", "-q", "origin", "HEAD:main"])
    # As `Ravix.Spec` opens a track: a branch from the remote's default, so
    # its upstream is `origin/main` until its first push.
    git!(work, ["checkout", "-q", "-b", "ravix/track", "origin/main"])

    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project, slug: "track", workdir: work)

    stub(Ravix.Config, :sprites, fn -> SpritesFake.config() end)
    fountain(project)
    machine(tmp)

    {:ok, owner: owner, project: project, track: track, work: work, remote: remote, tmp: tmp}
  end

  describe "git_status/2" do
    test "counts what porcelain and rev-list count on the machine", ctx do
      assert {:ok,
              %Git.Status{uncommitted: 0, unpushed: 0, upstream?: true, branch: "ravix/track"}} =
               Tracks.git_status(ctx.owner, ctx.track.id)

      File.write!(Path.join(ctx.work, "README"), "two\n")
      File.write!(Path.join(ctx.work, "new file.txt"), "new\n")
      File.write!(Path.join(ctx.work, "other"), "x\n")

      assert {:ok, %Git.Status{uncommitted: 3, unpushed: 0}} =
               Tracks.git_status(ctx.owner, ctx.track.id)

      git!(ctx.work, ["commit", "-q", "-am", "local one"])
      git!(ctx.work, ["commit", "-q", "--allow-empty", "-m", "local two"])

      assert {:ok, %Git.Status{uncommitted: 2, unpushed: 2, upstream?: true}} =
               Tracks.git_status(ctx.owner, ctx.track.id)
    end

    test "a branch without an upstream counts the commits no remote has", ctx do
      git!(ctx.work, ["branch", "--unset-upstream"])
      git!(ctx.work, ["commit", "-q", "--allow-empty", "-m", "local"])

      assert {:ok, %Git.Status{unpushed: 1, upstream?: false}} =
               Tracks.git_status(ctx.owner, ctx.track.id)
    end

    test "a stranger is refused before the machine is asked", ctx do
      assert {:error, :not_found} = Tracks.git_status(insert_user(), ctx.track.id)
      assert SpritesFake.calls() == []
    end

    test "a machine that is not running is not woken to be read", ctx do
      SpritesFake.install(fn conn, call ->
        assert call.method == "GET"
        Plug.Conn.send_resp(conn, 200, ~s({"status":"cold"}))
      end)

      assert {:error, :machine_asleep} = Tracks.git_status(ctx.owner, ctx.track.id)
      refute Enum.any?(SpritesFake.calls(), &(&1.method == "POST"))
    end

    test "a working directory that is not a repository says so", ctx do
      File.rm_rf!(Path.join(ctx.work, ".git"))

      assert {:error, {:conflict, "not_a_repository", _}} =
               Tracks.git_status(ctx.owner, ctx.track.id)
    end
  end

  describe "commit_and_push/3" do
    test "stages everything, commits the message with the committer's trailer and pushes", ctx do
      stub(Ravix.Config, :workspace_access?, fn -> true end)
      File.write!(Path.join(ctx.work, "README"), "two\n")
      File.write!(Path.join(ctx.work, "added"), "new\n")

      assert :ok = Tracks.commit_and_push(ctx.owner, ctx.track.id, "Fix it's quoting; $(nope)")

      assert {:ok, %Git.Status{uncommitted: 0, unpushed: 0, upstream?: true}} =
               Tracks.git_status(ctx.owner, ctx.track.id)

      message = git!(ctx.remote, ["log", "-1", "--format=%B", "ravix/track"])
      assert message =~ "Fix it's quoting; $(nope)"
      assert message =~ Attribution.trailer(ctx.owner)
      assert git!(ctx.remote, ["show", "--name-only", "--format=", "ravix/track"]) =~ "added"
    end

    test "a member who can run commands may commit; a stranger and a closed track may not",
         ctx do
      member = insert_user()
      insert_track_member(ctx.track, member)
      File.write!(Path.join(ctx.work, "added"), "new\n")

      assert {:error, :not_found} = Tracks.commit_and_push(insert_user(), ctx.track.id, "x")
      assert :ok = Tracks.commit_and_push(member, ctx.track.id, "From a member")

      Repo.update!(Ecto.Changeset.change(ctx.track, closed_at: DateTime.utc_now()))

      assert {:error, {:conflict, "closed_track", _}} =
               Tracks.commit_and_push(ctx.owner, ctx.track.id, "x")
    end

    test "an empty message and a clean worktree are refused", ctx do
      assert {:error, {:unprocessable, "empty_message", _}} =
               Tracks.commit_and_push(ctx.owner, ctx.track.id, "  ")

      assert {:error, {:unprocessable, "message_too_long", _}} =
               Tracks.commit_and_push(
                 ctx.owner,
                 ctx.track.id,
                 String.duplicate("'", Git.message_max() + 1)
               )

      assert {:error, {:conflict, "nothing_to_commit", _}} =
               Tracks.commit_and_push(ctx.owner, ctx.track.id, "Nothing")
    end

    test "a failing commit hook is surfaced with its output and nothing is pushed", ctx do
      hook = Path.join([ctx.work, ".git", "hooks", "pre-commit"])
      File.write!(hook, "#!/bin/sh\necho 'lint: 2 problems in added' >&2\nexit 1\n")
      File.chmod!(hook, 0o755)
      File.write!(Path.join(ctx.work, "added"), "new\n")

      assert {:error, {:conflict, "commit_failed", message}} =
               Tracks.commit_and_push(ctx.owner, ctx.track.id, "Blocked")

      assert message =~ "A commit hook may have failed"
      assert message =~ "lint: 2 problems in added"
      assert {:ok, %Git.Status{uncommitted: 1}} = Tracks.git_status(ctx.owner, ctx.track.id)
    end

    test "a rejected push says the commit landed and why the push did not", ctx do
      # Somebody else pushed the branch first.
      other = Path.join(ctx.tmp, "other")
      git!(ctx.tmp, ["clone", "-q", ctx.remote, other])

      git!(other, [
        "-c",
        "user.name=O",
        "-c",
        "user.email=o@example.test",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "theirs"
      ])

      git!(other, ["push", "-q", "origin", "HEAD:ravix/track"])

      File.write!(Path.join(ctx.work, "added"), "new\n")

      assert {:error, {:conflict, "push_rejected", message}} =
               Tracks.commit_and_push(ctx.owner, ctx.track.id, "Mine")

      assert message =~ "Committed, but the push failed."
      assert message =~ "rejected"
      assert {:ok, %Git.Status{uncommitted: 0}} = Tracks.git_status(ctx.owner, ctx.track.id)
    end
  end

  describe "push/2" do
    test "pushes the branch and sets its upstream", ctx do
      git!(ctx.work, ["commit", "-q", "--allow-empty", "-m", "local"])
      assert :ok = Tracks.push(ctx.owner, ctx.track.id)

      assert git!(ctx.work, ["rev-parse", "--abbrev-ref", "@{upstream}"]) ==
               "origin/ravix/track\n"

      assert {:ok, %Git.Status{unpushed: 0}} = Tracks.git_status(ctx.owner, ctx.track.id)
    end

    test "a failing pre-push hook is surfaced with its output", ctx do
      hook = Path.join([ctx.work, ".git", "hooks", "pre-push"])
      File.write!(hook, "#!/bin/sh\necho 'tests failed: 3' >&2\nexit 1\n")
      File.chmod!(hook, 0o755)
      git!(ctx.work, ["commit", "-q", "--allow-empty", "-m", "local"])

      assert {:error, {:conflict, "push_failed", message}} = Tracks.push(ctx.owner, ctx.track.id)
      assert message =~ "The push failed."
      assert message =~ "tests failed: 3"
      refute message =~ "Committed"
    end

    test "no remote and a detached HEAD are told apart", ctx do
      git!(ctx.work, ["remote", "remove", "origin"])
      assert {:error, {:conflict, "no_upstream", _}} = Tracks.push(ctx.owner, ctx.track.id)

      git!(ctx.work, ["checkout", "-q", "--detach"])
      assert {:error, {:conflict, "detached_head", _}} = Tracks.push(ctx.owner, ctx.track.id)
    end

    test "a machine that does not answer is an error, not a success", ctx do
      SpritesFake.install(fn conn, %{method: method} ->
        if method == "GET",
          do: Plug.Conn.send_resp(conn, 200, ~s({"status":"running"})),
          else: Plug.Conn.send_resp(conn, 502, "bad gateway")
      end)

      assert {:error, _} = Tracks.push(ctx.owner, ctx.track.id)
    end
  end

  # A Fountain whose project has one machine, on a sprite.
  defp fountain(project) do
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
          {%{method: "GET", path: "/api/sandboxes/sb-1"},
           {200, [], %{data: %{id: "sb-1", sprite_name: "sprite-7"}}}}
        ],
        verify: false
      )

    stub(Ravix.Fountain, :client, fn -> client end)
  end

  # The sprite: running, and every exec is the script run here.
  defp machine(tmp) do
    SpritesFake.install(fn conn, call ->
      case call do
        %{method: "GET"} ->
          Plug.Conn.send_resp(conn, 200, ~s({"status":"running"}))

        %{argv: ["sh", "-lc", script]} ->
          {out, code} = System.cmd("sh", ["-c", script], env: env(tmp), stderr_to_stdout: true)
          SpritesFake.exec_response(conn, out, "", code)
      end
    end)
  end

  defp git!(dir, args) do
    {out, 0} =
      System.cmd("git", args, cd: dir, env: env(Path.dirname(dir)), stderr_to_stdout: true)

    out
  end

  # No global or system configuration leaks in, from this machine or CI's.
  defp env(tmp),
    do: [
      {"HOME", tmp},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_TERMINAL_PROMPT", "0"},
      # The temporary directory may sit inside a checkout, as it does in
      # this repository's own; Git must not find that one above it.
      {"GIT_CEILING_DIRECTORIES", tmp}
    ]
end
