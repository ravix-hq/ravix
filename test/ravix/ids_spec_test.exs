defmodule Ravix.IdsSpecTest do
  use ExUnit.Case, async: true

  alias Ravix.{Ids, Spec}
  alias Ravix.Projects.Project
  alias Ravix.Tracks.Origin

  # The expected strings here were produced by `shared/ids.ts` and
  # `shared/spec.ts` under bun; the port is held to them exactly.

  # `Ravix.Tracks.Origin` enforces all five keys, so a test that cares about
  # two of them still has to say so. This fills in the rest.
  #
  # A case that used to be here and cannot be now: `open_track_prompt/4` was
  # asserted to answer the same prompt for `kind: "pr"` as for `kind: :pr`,
  # because `Ravix.Spec` narrowed the kind a second time through a private
  # `kind_of/1`. No production caller ever passed the string --- the only two
  # are `read_origin/2`, which resolves against `Track.origin_kinds/0`, and a
  # row's `Ecto.Enum` column --- and the struct makes the string
  # unrepresentable, so the tolerance and the test for it went together.
  # `Ravix.Spec` takes the project for the three prompts that used to take a
  # path somebody else derived, so these fixtures say what a project *is*.
  # `Project.repo_path/1` is `Ids.mount_path_for/1`, which keeps the last
  # segment: `"acme/r"` is `/workspace/r`.
  defp project(fields \\ []) do
    struct!(
      Project,
      Keyword.merge([name: "Ravix", repo_full_name: nil, default_branch: nil], fields)
    )
  end

  defp origin(fields) do
    struct!(
      %Origin{kind: :blank, base: nil, number: nil, title: nil, url: nil},
      fields
    )
  end

  describe "Ravix.Ids" do
    test "slugify is fit for a directory, a branch and a URL at once" do
      assert Ids.slugify("Hello World!") == "hello-world"
      assert Ids.slugify("--a--b--") == "a-b"
      assert Ids.slugify("Ünïcödé Name") == "u-ni-co-de-name"
      assert Ids.slugify("") == "track"
      assert Ids.slugify("", "sy") == "sy"
      assert Ids.slugify(String.duplicate("a", 60) <> "-x") == String.duplicate("a", 40)
      assert Ids.slugify("trailing-.lock") == "trailing-lock"
    end

    test "a track's channel carries the project, the slug and the revision, and parses back" do
      assert Ids.track_channel("p1", "kyoto", 3) == "ravix:p1:kyoto@r3"

      assert Ids.parse_channel("ravix:p1:kyoto@r3") == %{
               project_id: "p1",
               track_slug: "kyoto",
               rev: 3
             }

      assert Ids.parse_channel("ravix:p1") == nil
      assert Ids.parse_channel(nil) == nil
      assert Ids.project_channel?("ravix:p1:kyoto@r3", "p1")
      refute Ids.project_channel?("ravix:p2:kyoto@r3", "p1")
      assert Ids.project_channel("p1") == "ravix:p1"
    end

    test "branch names follow Git ref rules without changing spelling" do
      for name <- ["fix", "Fix-123", "feature/import", "éclair", "a+b", "a'b", "$HOME"] do
        assert Ids.valid_branch_name?(name), name
        assert {_, 0} = System.cmd("git", ["check-ref-format", "--branch", "ravix/#{name}"])
      end

      for name <- [
            "",
            "@",
            "-fix",
            "two words",
            "a..b",
            "a~b",
            "a^b",
            "a:b",
            "a?b",
            "a*b",
            "a[b",
            "a\\b",
            ".hidden",
            "a/.hidden",
            "a.lock",
            "a.lock/b",
            "a/",
            "/a",
            "a//b",
            "a.",
            "a@{b",
            "a\n",
            "a\t",
            <<127>>,
            nil,
            123
          ] do
        refute Ids.valid_branch_name?(name), inspect(name)
      end
    end

    test "branches, workdirs and mount paths" do
      assert Ids.branch_for("kyoto") == "ravix/kyoto"
      assert Ids.workdir_for("kyoto") == "/home/sprite/work/kyoto"
      assert Ids.mount_path_for("acme/widgets") == "/workspace/widgets"
      assert Ids.mount_path_for("plain") == "/workspace/plain"
    end

    test "a project's clone path is nil when it has no repository, blank included" do
      assert Project.repo_path(project(repo_full_name: "acme/widgets")) == "/workspace/widgets"
      assert Project.repo_path(project()) == nil

      # The two spellings this replaced disagreed here. `repo_full_name && ...`
      # handed `""` to `Ids.mount_path_for/1`, which answers `"/workspace/"`;
      # the private `repo_path/1` in `Ravix.Tracks` answered nil. `create/2`
      # maps a blank repository to nil, so no row reaches either, but a project
      # with a blank name has no clone and this is the spelling that says so.
      assert Project.repo_path(project(repo_full_name: "")) == nil
    end
  end

  describe "Ravix.Spec" do
    test "the system prompt names the clone and the trunk only when there is a repository" do
      with_repo =
        Spec.system_prompt(project(repo_full_name: "acme/ravix", default_branch: "main"))

      assert with_repo =~ "  - /workspace/ravix is the shared clone."
      assert with_repo =~ "The trunk is `main`. Branch from it and merge back to it."
      assert with_repo =~ "Git is configured for pushing"

      no_trunk = Spec.system_prompt(project(name: "X", repo_full_name: "acme/x"))

      refute no_trunk =~ "The trunk is"
      assert no_trunk =~ "Git is configured for pushing"

      blank = Spec.system_prompt(project(name: "Blank"))
      refute blank =~ "shared clone"
      refute blank =~ "Git is configured"
      assert blank =~ "## Live previews"
      assert String.ends_with?(blank, "back verbatim.")
    end

    test "opening commands quote Git names containing shell metacharacters" do
      prompt =
        Spec.open_track_prompt(
          project(repo_full_name: "acme/r"),
          origin(kind: :blank),
          "safe",
          "ravix/$HOME"
        )

      assert prompt =~ "-b 'ravix/$HOME'"
    end

    test "the opening turn cuts a worktree from the origin, or a plain directory" do
      blank = Spec.open_track_prompt(project(), origin(kind: :blank), "s", "me/s-1")

      assert blank =~ "  mkdir -p /home/sprite/work/s && cd /home/sprite/work/s"

      fresh =
        Spec.open_track_prompt(
          project(repo_full_name: "acme/r"),
          origin(kind: :blank, base: "main"),
          "s",
          "me/s-1"
        )

      assert fresh =~ "Cut a new branch `me/s-1` from `origin/main`:"

      assert fresh =~
               "  git worktree add /home/sprite/work/s -b me/s-1 origin/main 2>/dev/null \\"

      assert fresh =~ "    || mkdir -p /home/sprite/work/s"

      existing =
        Spec.open_track_prompt(
          project(repo_full_name: "acme/r"),
          origin(kind: :branch, base: "feature/x"),
          "s",
          "me/s-1"
        )

      assert existing =~ "Cut a new branch `me/s-1` from `origin/feature/x`:"
      refute existing =~ "git worktree add /home/sprite/work/s feature/x"

      pr =
        Spec.open_track_prompt(
          project(repo_full_name: "acme/r"),
          origin(kind: :pr, number: 7),
          "s",
          "me/s-1"
        )

      assert pr =~ "This track continues pull request #7."

      assert pr =~ "  git fetch origin 'pull/7/head:me/s-1' 2>/dev/null \\"
      assert pr =~ "    || git worktree add /home/sprite/work/s -b me/s-1 HEAD"

      issue =
        Spec.open_track_prompt(
          project(repo_full_name: "acme/r"),
          origin(kind: :issue, base: "main", number: 9, title: "Fix it"),
          "s",
          "me/s-1"
        )

      assert issue =~ ~s(This track exists to work on issue #9, "Fix it". Do not start)
      assert issue =~ "Cut a new branch `me/s-1` from `origin/main`:"
    end

    test "the closing turn removes the worktree and leaves the branch alone unless asked" do
      plain = Spec.close_track_prompt(project(), "s")
      assert plain =~ "  rm -rf /home/sprite/work/s"

      gentle = Spec.close_track_prompt(project(repo_full_name: "acme/r"), "s")
      assert gentle =~ "  git worktree remove /home/sprite/work/s\n  git worktree prune"
      assert gentle =~ "Leave the branch alone"

      assert gentle =~
               "If the worktree has uncommitted changes, stop and say so instead of forcing it."

      forced =
        Spec.close_track_prompt(project(repo_full_name: "acme/r"), "s",
          force: true,
          delete_branch: "me/s-1"
        )

      assert forced =~ "  git worktree remove --force /home/sprite/work/s"

      assert forced =~
               "  git branch -D me/s-1\n  git push origin --delete me/s-1 2>/dev/null || true"

      assert forced =~ "This is a forced close"
    end

    test "the survey writes the receipt, and the starters depend on having a repository" do
      assert Spec.receipt_path() == "/home/sprite/.ravix/tracks.json"

      assert Spec.survey_prompt() =~
               "Then write /home/sprite/.ravix/tracks.json (mkdir -p /home/sprite/.ravix first)."

      assert length(Spec.starters(project())) == 2

      assert [%{label: "Set up live preview"} | _] =
               Spec.starters(project(repo_full_name: "acme/r"))
    end
  end
end
