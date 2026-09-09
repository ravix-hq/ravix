defmodule Ravix.IdsSpecTest do
  use ExUnit.Case, async: true

  alias Ravix.{Ids, Spec}

  # The expected strings here were produced by `shared/ids.ts` and
  # `shared/spec.ts` under bun; the port is held to them exactly.

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

    test "branches, workdirs and mount paths" do
      assert Ids.branch_for("Jake Gaylor", "kyoto", "abc") == "jake-gaylor/kyoto-abc"
      assert Ids.workdir_for("kyoto") == "/home/sprite/work/kyoto"
      assert Ids.mount_path_for("acme/widgets") == "/workspace/widgets"
      assert Ids.mount_path_for("plain") == "/workspace/plain"
    end
  end

  describe "Ravix.Spec" do
    test "the system prompt names the clone and the trunk only when there is a repository" do
      with_repo =
        Spec.system_prompt(%{
          project: "Ravix",
          repo_path: "/workspace/ravix",
          default_branch: "main"
        })

      assert with_repo =~ "  - /workspace/ravix is the shared clone."
      assert with_repo =~ "The trunk is `main`. Branch from it and merge back to it."
      assert with_repo =~ "Git is configured for pushing"

      no_trunk =
        Spec.system_prompt(%{project: "X", repo_path: "/workspace/x", default_branch: nil})

      refute no_trunk =~ "The trunk is"
      assert no_trunk =~ "Git is configured for pushing"

      blank = Spec.system_prompt(%{project: "Blank", repo_path: nil, default_branch: nil})
      refute blank =~ "shared clone"
      refute blank =~ "Git is configured"
      assert blank =~ "## Live previews"
      assert String.ends_with?(blank, "back verbatim.")
    end

    test "the opening turn cuts a worktree from the origin, or a plain directory" do
      blank =
        Spec.open_track_prompt(%{
          slug: "s",
          branch: "me/s-1",
          repo_path: nil,
          origin: %{kind: :blank, base: nil}
        })

      assert blank =~ "  mkdir -p /home/sprite/work/s && cd /home/sprite/work/s"

      fresh =
        Spec.open_track_prompt(%{
          slug: "s",
          branch: "me/s-1",
          repo_path: "/workspace/r",
          origin: %{kind: :blank, base: "main"}
        })

      assert fresh =~ "Cut a new branch `me/s-1` from `origin/main`:"

      assert fresh =~
               "  git worktree add /home/sprite/work/s -b me/s-1 origin/main 2>/dev/null \\"

      assert fresh =~ "    || mkdir -p /home/sprite/work/s"

      existing =
        Spec.open_track_prompt(%{
          slug: "s",
          branch: "me/s-1",
          repo_path: "/workspace/r",
          origin: %{kind: :branch, base: "feature/x"}
        })

      assert existing =~ "This track continues the existing branch `feature/x`:"
      assert existing =~ "    || git worktree add /home/sprite/work/s feature/x 2>/dev/null \\"

      pr =
        Spec.open_track_prompt(%{
          slug: "s",
          branch: "me/s-1",
          repo_path: "/workspace/r",
          origin: %{kind: :pr, base: nil, number: 7}
        })

      assert pr =~ "This track continues pull request #7."

      assert pr ==
               Spec.open_track_prompt(%{
                 slug: "s",
                 branch: "me/s-1",
                 repo_path: "/workspace/r",
                 origin: %{kind: "pr", base: nil, number: 7}
               })

      assert pr =~ "  git fetch origin pull/7/head:me/s-1 2>/dev/null \\"
      assert pr =~ "    || git worktree add /home/sprite/work/s -b me/s-1 HEAD"

      issue =
        Spec.open_track_prompt(%{
          slug: "s",
          branch: "me/s-1",
          repo_path: "/workspace/r",
          origin: %{kind: :issue, base: "main", number: 9, title: "Fix it"}
        })

      assert issue =~ ~s(This track exists to work on issue #9, "Fix it". Do not start)
      assert issue =~ "Cut a new branch `me/s-1` from `origin/main`:"
    end

    test "the closing turn removes the worktree and leaves the branch alone unless asked" do
      plain = Spec.close_track_prompt(%{slug: "s", repo_path: nil, force: false})
      assert plain =~ "  rm -rf /home/sprite/work/s"

      gentle = Spec.close_track_prompt(%{slug: "s", repo_path: "/workspace/r", force: false})
      assert gentle =~ "  git worktree remove /home/sprite/work/s\n  git worktree prune"
      assert gentle =~ "Leave the branch alone"

      assert gentle =~
               "If the worktree has uncommitted changes, stop and say so instead of forcing it."

      forced =
        Spec.close_track_prompt(%{
          slug: "s",
          repo_path: "/workspace/r",
          force: true,
          delete_branch: "me/s-1"
        })

      assert forced =~ "  git worktree remove --force /home/sprite/work/s"

      assert forced =~
               "  git branch -D me/s-1\n  git push origin --delete me/s-1 2>/dev/null || true"

      assert forced =~ "This is a forced close"
    end

    test "the survey writes the receipt, and the starters depend on having a repository" do
      assert Spec.receipt_path() == "/home/sprite/.ravix/tracks.json"

      assert Spec.survey_prompt() =~
               "Then write /home/sprite/.ravix/tracks.json (mkdir -p /home/sprite/.ravix first)."

      assert length(Spec.starters(%{has_repo: false})) == 2
      assert [%{label: "Set up live preview"} | _] = Spec.starters(%{has_repo: true})
    end
  end
end
