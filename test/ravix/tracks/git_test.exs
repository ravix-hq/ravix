defmodule Ravix.Tracks.GitTest do
  use ExUnit.Case, async: true

  alias Ravix.Tracks.Git

  defp result(code, stdout, opts \\ []),
    do: %{code: code, stdout: stdout, stderr: "", timed_out: Keyword.get(opts, :timed_out, false)}

  describe "parse_status/1" do
    test "counts porcelain entries and reads the ahead count" do
      out = " M a\n?? b c\nR  d -> e\n__ravix_git__\nravix/x\nupstream 4\n"

      assert {:ok, %Git.Status{uncommitted: 3, unpushed: 4, upstream?: true, branch: "ravix/x"}} =
               Git.parse_status(result(0, out))

      assert {:ok, %Git.Status{uncommitted: 0, unpushed: 0, upstream?: false, branch: nil}} =
               Git.parse_status(result(0, "__ravix_git__\n\nnone 0\n"))
    end

    test "output it cannot read is an error rather than a zero" do
      for out <- ["", "__ravix_git__\nmain\n", "__ravix_git__\nmain\nupstream many\n"] do
        assert {:error, {:unavailable, "git_status_unreadable", _}} =
                 Git.parse_status(result(0, out))
      end

      assert {:error, {:conflict, "not_a_repository", _}} = Git.parse_status(result(15, ""))
    end
  end

  describe "written/2" do
    test "names the step that failed" do
      assert :ok = Git.written(result(0, ""), :commit)
      assert {:error, {:conflict, "stage_failed", _}} = Git.written(result(10, ""), :commit)
      assert {:error, {:conflict, "nothing_to_commit", _}} = Git.written(result(13, ""), :commit)
      assert {:error, {:conflict, "detached_head", _}} = Git.written(result(14, ""), :push)
      assert {:error, {:conflict, "git_failed", _}} = Git.written(result(1, "boom"), :push)

      assert {:error, {:unavailable, "git_timeout", _}} =
               Git.written(result(124, "", timed_out: true), :commit)
    end

    for {output, code} <- [
          {"remote: error: GH006: Protected branch update failed\n ! [remote rejected] HEAD -> main (protected branch hook declined)",
           "push_refused"},
          {"fatal: Authentication failed for 'https://github.com/acme/repo.git/'",
           "push_unauthorized"},
          {"remote: Permission to acme/repo.git denied to bot.\nfatal: unable to access",
           "push_unauthorized"},
          {" ! [rejected]        HEAD -> ravix/x (fetch first)\nerror: failed to push some refs",
           "push_rejected"},
          {"fatal: No configured push destination.", "no_upstream"},
          {"error: failed to push some refs to 'origin'", "push_failed"}
        ] do
      @output output
      @code code
      test "a push failing with #{code} says so: #{String.slice(output, 0, 24)}" do
        assert {:error, {:conflict, @code, message}} = Git.written(result(12, @output), :push)
        refute message =~ "Committed"

        assert {:error, {:conflict, @code, "Committed, but" <> _}} =
                 Git.written(result(12, @output), :commit)
      end
    end

    test "the credential in a remote URL and anything shaped like a token are not shown" do
      out =
        "fatal: unable to access 'https://x-access-token:ghs_abc123DEF@github.com/acme/repo.git/': 403\n" <>
          "token ghp_secretSECRET1 leaked"

      assert {:error, {:conflict, _, message}} = Git.written(result(12, out), :push)
      refute message =~ "ghs_abc123DEF"
      refute message =~ "x-access-token"
      refute message =~ "ghp_secretSECRET1"
      assert message =~ "https://github.com/acme/repo.git/"
    end

    test "only the tail of a long failure is kept" do
      out = Enum.map_join(1..50, "\n", &("line #{&1} " <> String.duplicate("x", 200)))

      assert {:error, {:conflict, "commit_failed", message}} =
               Git.written(result(11, out), :commit)

      assert message =~ "line 50"
      refute message =~ "line 40 "
      assert String.length(message) < 1_000
    end
  end

  test "the commit message is one quoted argument" do
    command = Git.commit_and_push_command("it's $(rm -rf /) `x`")
    assert command =~ ~S"git commit -q -m 'it'\''s $(rm -rf /) `x`'"
  end
end
