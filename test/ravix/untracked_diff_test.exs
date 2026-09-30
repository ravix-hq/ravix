defmodule Ravix.UntrackedDiffTest do
  use ExUnit.Case, async: true
  alias Ravix.Tracks.Diff

  setup do
    base = Path.expand("tmp/untracked-diff-#{System.unique_integer([:positive])}")
    root = Path.join(base, "repo")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(base) end)
    git(root, ["init", "-q"])
    File.write!(Path.join(root, "tracked.txt"), "one\n")
    git(root, ["add", "tracked.txt"])
    git(root, ["-c", "user.email=a@b", "-c", "user.name=a", "commit", "-qm", "init"])
    %{root: root}
  end

  defp git(root, args), do: {_, 0} = System.cmd("git", ["-C", root | args])

  defp run(root) do
    {output, 0} = System.cmd("sh", ["-c", Diff.untracked_command(root)], cd: root)
    {:ok, %{code: 0, stdout: output}}
  end

  defp tracked(text) do
    files = Diff.parse(text)

    %Diff{
      path: nil,
      repo_root: nil,
      diff: text,
      truncated: false,
      changes: Enum.map(files, & &1.change),
      files: files
    }
  end

  test "untracked files join the diff as new, ignored ones do not, and nothing is written", %{
    root: root
  } do
    File.write!(Path.join(root, ".gitignore"), "*.log\n")
    File.write!(Path.join(root, "debug.log"), "ignored\n")
    File.mkdir_p!(Path.join(root, "src"))
    File.write!(Path.join(root, "src/new.ex"), "a\nb\n")
    File.write!(Path.join(root, "$(touch injected).txt"), "x\n")
    File.write!(Path.join(root, "tracked.txt"), "one\ntwo\n")
    # `git status` refreshes the index itself, so it goes first.
    status = System.cmd("git", ["-C", root, "status", "--porcelain"])
    index = File.read!(Path.join(root, ".git/index"))

    edit =
      "diff --git a/tracked.txt b/tracked.txt\n--- a/tracked.txt\n+++ b/tracked.txt\n" <>
        "@@ -1 +1,2 @@\n one\n+two\n"

    diff = Diff.with_untracked(tracked(edit), run(root))

    assert Enum.map(diff.changes, &{&1.path, &1.status, &1.added}) == [
             {"tracked.txt", :modified, 1},
             {"$(touch injected).txt", :untracked, 1},
             {".gitignore", :untracked, 1},
             {"src/new.ex", :untracked, 2}
           ]

    assert %{hunks: [%{lines: [%{text: "a", new: 1}, %{text: "b", new: 2}]}]} =
             Enum.find(diff.files, &(&1.change.path == "src/new.ex"))

    refute diff.truncated
    refute File.exists?(Path.join(root, "injected"))
    assert File.read!(Path.join(root, ".git/index")) == index
    assert System.cmd("git", ["-C", root, "status", "--porcelain"]) == status
  end

  test "a file over the size is listed with no lines; a path already in the diff is not doubled",
       %{root: root} do
    File.write!(Path.join(root, "big.bin"), String.duplicate("a", 300_000))
    File.write!(Path.join(root, "added.txt"), "x\n")

    intent =
      "diff --git a/added.txt b/added.txt\nnew file mode 100644\n--- /dev/null\n" <>
        "+++ b/added.txt\n@@ -0,0 +1 @@\n+x\n"

    diff = Diff.with_untracked(tracked(intent), run(root))

    assert [
             %{change: %{path: "added.txt", status: :added}},
             %{change: %{path: "big.bin", status: :untracked, added: 0}, hunks: [], partial: true}
           ] = diff.files
  end

  test "more files than the cap are cut and the diff says so", %{root: root} do
    for n <- 1..201, do: File.write!(Path.join(root, "f#{n}.txt"), "#{n}\n")
    diff = Diff.with_untracked(tracked(""), run(root))
    assert length(diff.files) == 200
    assert diff.truncated
  end

  test "a clean worktree is listed as clean; a non-repository or failed exec is unread", %{
    root: root
  } do
    clean = tracked("")
    assert clean.untracked == :unread
    assert Diff.with_untracked(clean, run(root)) == %{clean | untracked: :listed}
    assert Diff.with_untracked(clean, :asleep) == %{clean | untracked: :asleep}

    outside = Path.join(Path.dirname(root), "plain")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "a.txt"), "a\n")
    assert Diff.with_untracked(clean, run(outside)) == clean

    for result <- [
          {:error, :not_found},
          {:ok, %{code: 1, stdout: ""}},
          {:ok, %{code: 0, stdout: "not json"}},
          :timeout
        ] do
      assert Diff.with_untracked(clean, result) == clean
    end
  end
end
