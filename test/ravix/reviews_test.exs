defmodule Ravix.ReviewsTest do
  use Ravix.DataCase, async: true
  use Mimic
  alias Ravix.{Comments, Hub, People, PromptQueue, Reviews, Tracks}
  alias Ravix.Reviews.{Anchor, Discussion}
  alias Ravix.Tracks.Diff

  setup do
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project)
    guest = insert_user()
    insert_track_member(track, guest, role: :read)
    patch = File.read!("test/fixtures/diff/files.patch")
    diff = diff(patch)
    stub(Tracks, :diff, fn _, _ -> {:ok, diff} end)
    %{user: user, guest: guest, project: project, track: track, diff: diff}
  end

  test "old/new anchors retain revision and escaped text; replies and resolution persist without prompts",
       c do
    Hub.subscribe(c.project.id)

    assert {:ok, old} =
             Reviews.open(
               c.guest,
               c.track.id,
               anchor(c, "space name.txt", "old", 2),
               "Review deletion"
             )

    assert {:ok, new} =
             Reviews.open(
               c.user,
               c.track.id,
               anchor(c, "space name.txt", "new", "2"),
               "  Review insertion  "
             )

    assert {old.side, old.line, old.excerpt} == {"old", 2, "two"}
    assert new.excerpt == "<script>alert(1)</script>"
    assert new.revision == Anchor.revision(c.diff, new.path)
    assert hd(new.messages).body == "Review insertion"
    assert hd(old.messages).author.id == c.guest.id
    assert_receive {:hub, %{name: :review}}
    assert {:ok, reply} = Reviews.reply(c.guest, c.track.id, new.id, "Answer")
    assert reply.author_id == c.guest.id
    assert {:ok, %{resolved: true}} = Reviews.resolve(c.guest, c.track.id, new.id, true)
    assert {:ok, rows} = Reviews.list(c.user, c.track.id)
    listed = Enum.find(rows, &(&1.id == new.id))
    assert listed.resolved
    assert Enum.map(listed.messages, & &1.body) == ["Review insertion", "Answer"]
    assert {:ok, %{resolved: false}} = Reviews.resolve(c.user, c.track.id, new.id, false)
    assert {:ok, []} = Comments.list(c.user, c.track.id, nil)
    assert {:ok, []} = PromptQueue.list(c.user, c.track.id)
  end

  test "binary, deleted and metadata files anchor honestly", c do
    for path <- ["binary.dat", "mode.sh", "new name.txt"] do
      assert {:ok, %{line: nil, side: "file"}} =
               Reviews.open(c.user, c.track.id, anchor(c, path, "file", nil), path)
    end

    assert {:ok, %{excerpt: "deleted", side: "old"}} =
             Reviews.open(c.user, c.track.id, anchor(c, "deleted.txt", "old", 1), "Deleted line")

    for {path, side, line} <- [
          {"binary.dat", "new", 1},
          {"deleted.txt", "new", 1},
          {"added.txt", "old", 1},
          {"mode.sh", "new", 1},
          {"missing", "file", nil},
          {"added.txt", "new", "1junk"},
          {"added.txt", "bogus", 1},
          {"added.txt", "file", 1}
        ] do
      assert {:error, {:unprocessable, "review_anchor", _}} =
               Reviews.open(c.user, c.track.id, anchor(c, path, side, line), "Invalid")
    end
  end

  test "changed diffs refuse stale submissions but retain discussions, replies and resolution",
       c do
    position = anchor(c, "added.txt", "new", 1)
    {:ok, discussion} = Reviews.open(c.user, c.track.id, position, "Original")
    updated = diff(String.replace(c.diff.diff, "++++ content", "+changed"))
    stub(Tracks, :diff, fn _, _ -> {:ok, updated} end)

    assert {:error, {:conflict, "stale_review", _}} =
             Reviews.open(c.user, c.track.id, position, "Stale")

    assert {:ok, [original]} = Reviews.list(c.user, c.track.id)
    assert original.id == discussion.id
    assert original.excerpt == "+++ content"
    refute original.revision == Anchor.revision(updated, original.path)
    assert {:ok, _} = Reviews.reply(c.user, c.track.id, original.id, "Still useful")
    assert {:ok, %{resolved: true}} = Reviews.resolve(c.user, c.track.id, original.id, true)
    assert {:ok, []} = Comments.list(c.user, c.track.id, nil)
  end

  test "out-of-scope IDs and revoked membership never reach review rows or providers", c do
    {:ok, row} = Reviews.open(c.user, c.track.id, anchor(c, "added.txt", "file", nil), "Private")
    outsider = insert_user()
    other = insert_track()
    reject(Tracks, :diff, 2)
    assert {:error, :not_found} = Reviews.open(outsider, c.track.id, %{}, "No")
    assert {:error, :not_found} = Reviews.list(outsider, c.track.id)
    assert {:error, :not_found} = Reviews.reply(outsider, c.track.id, row.id, "No")
    assert {:error, :not_found} = Reviews.resolve(outsider, c.track.id, row.id, true)
    assert {:error, :not_found} = Reviews.reply(c.user, c.track.id, other.id, "No")
    assert {:error, :not_found} = Reviews.resolve(c.user, other.id, row.id, true)
    assert {:ok, _} = People.remove(c.user, c.track.id, c.guest.login)
    assert {:error, :not_found} = Reviews.reply(c.guest, c.track.id, row.id, "Removed")
    assert {:error, :not_found} = Reviews.list(c.guest, c.track.id)
  end

  test "blank/oversized bodies roll back anchors; invalid resolution and provider errors return tagged refusals",
       c do
    position = anchor(c, "added.txt", "file", nil)

    for body <- ["  ", String.duplicate("a", 10_001), nil] do
      assert {:error, %Ecto.Changeset{}} = Reviews.open(c.user, c.track.id, position, body)
    end

    assert Repo.aggregate(Discussion, :count) == 0
    {:ok, row} = Reviews.open(c.user, c.track.id, position, "Valid")
    assert {:error, %Ecto.Changeset{}} = Reviews.reply(c.user, c.track.id, row.id, " ")
    assert {:error, {:unprocessable, _, _}} = Reviews.resolve(c.user, c.track.id, row.id, "yes")
    stub(Tracks, :diff, fn _, _ -> {:error, :machine_asleep} end)
    assert {:error, :machine_asleep} = Reviews.open(c.user, c.track.id, position, "Unavailable")
    assert {:ok, [listed]} = Reviews.list(c.user, c.track.id)
    assert length(listed.messages) == 1
  end

  test "provider delays cannot write after membership or browser session revocation", c do
    position = anchor(c, "added.txt", "file", nil)

    stub(Tracks, :diff, fn _, _ ->
      People.remove(c.user, c.track.id, c.guest.login)
      {:ok, c.diff}
    end)

    assert {:error, :not_found} =
             Reviews.open(c.guest, c.track.id, position, "Removed during read")

    {token, session} = insert_session(c.user)

    stub(Tracks, :diff, fn _, _ ->
      Repo.delete!(session)
      {:ok, c.diff}
    end)

    assert {:error, :unauthenticated} =
             Reviews.open(c.user, c.track.id, position, "Ended during read",
               session_hash: Ravix.Crypto.sha256(token)
             )

    assert {:ok, []} = Reviews.list(c.user, c.track.id)
  end

  test "partial diff only accepts returned lines and its fingerprint differs from a complete read",
       c do
    partial = %{c.diff | truncated: true, files: Diff.parse(c.diff.diff, true)}
    assert is_nil(Anchor.revision(partial, "space name.txt"))
    assert is_binary(Anchor.revision(c.diff, "space name.txt"))

    assert {:error, {:unprocessable, _, _}} =
             Anchor.locate(partial, %{
               anchor(c, "added.txt", "new", 100)
               | "revision" => Anchor.revision(partial, "added.txt")
             })

    assert {:error, {:unprocessable, _, _}} = Anchor.locate(c.diff, nil)
  end

  test "tracked anchors match a reader even when a writer sees extra untracked files", c do
    reader = %{c.diff | untracked: :unread}

    extra =
      "diff --git a/notes.txt b/notes.txt\nnew file mode 100644\n--- /dev/null\n+++ b/notes.txt\n@@ -0,0 +1 @@\n+Writer-only content\n"

    writer =
      Diff.with_untracked(
        reader,
        {:ok,
         %{
           code: 0,
           stdout: Jason.encode!(%{available: true, diff: extra, large: [], truncated: false})
         }}
      )

    assert writer.untracked == :listed
    refute reader.diff == writer.diff
    path = "space name.txt"
    assert Anchor.revision(reader, path) == Anchor.revision(writer, path)

    stub(Tracks, :diff, fn user, _ ->
      {:ok, if(user.id == c.user.id, do: writer, else: reader)}
    end)

    {:ok, discussion} =
      Reviews.open(
        c.user,
        c.track.id,
        %{anchor(c, path, "new", 2) | "revision" => Anchor.revision(writer, path)},
        "Tracked"
      )

    assert {:ok, _} =
             Reviews.open(
               c.guest,
               c.track.id,
               %{anchor(c, path, "old", 2) | "revision" => discussion.revision},
               "Reader"
             )

    assert Anchor.status(discussion, Anchor.revisions(reader), reader.untracked) == :current
    assert {:ok, _} = Reviews.reply(c.guest, c.track.id, discussion.id, "Same content")
  end

  test "header-only oversized untracked files are unverifiable and cannot accept stale file posts",
       c do
    complete =
      diff(
        "diff --git a/large.txt b/large.txt\nnew file mode 100644\n--- /dev/null\n+++ b/large.txt\n@@ -0,0 +1 @@\n+Original\n"
      )

    stub(Tracks, :diff, fn _, _ -> {:ok, complete} end)

    position = %{
      "revision" => Anchor.revision(complete, "large.txt"),
      "path" => "large.txt",
      "side" => "file",
      "line" => nil
    }

    {:ok, discussion} = Reviews.open(c.user, c.track.id, position, "Original review")
    header = "diff --git a/large.txt b/large.txt\nnew file mode 100644\n"

    oversized =
      Diff.with_untracked(
        diff(""),
        {:ok,
         %{
           code: 0,
           stdout:
             Jason.encode!(%{
               available: true,
               diff: header,
               large: ["large.txt"],
               truncated: false
             })
         }}
      )

    assert hd(oversized.files).partial
    assert is_nil(Anchor.revision(oversized, "large.txt"))

    assert Anchor.status(discussion, Anchor.revisions(oversized), oversized.untracked) ==
             :unverifiable

    stub(Tracks, :diff, fn _, _ -> {:ok, oversized} end)

    for revision <- [position["revision"], nil] do
      assert {:error, {:conflict, "unverifiable_review", _}} =
               Reviews.open(
                 c.user,
                 c.track.id,
                 %{position | "revision" => revision},
                 "Cannot verify"
               )
    end

    assert {:ok, [retained]} = Reviews.list(c.user, c.track.id)
    assert retained.id == discussion.id
    assert {:ok, _} = Reviews.reply(c.user, c.track.id, retained.id, "Still retained")
  end

  test "binary revisions use Git blob indexes; missing identities never claim current", c do
    path = "binary.dat"
    {:ok, discussion} = Reviews.open(c.user, c.track.id, anchor(c, path, "file", nil), "Binary")
    changed = diff(String.replace(c.diff.diff, "e7be1ea..f9e371f", "e7be1ea..abcdef0"))
    assert Anchor.status(discussion, Anchor.revisions(changed), :listed) == :outdated
    unknown = diff(String.replace(c.diff.diff, "index e7be1ea..f9e371f 100644\n", ""))
    assert Anchor.status(discussion, Anchor.revisions(unknown), :listed) == :unverifiable

    assert {:error, {:conflict, "unverifiable_review", _}} =
             Anchor.locate(unknown, anchor(c, path, "file", nil))

    assert Anchor.status(discussion, %{}, :unread) == :unverifiable
    assert Anchor.status(discussion, %{}, :listed, true) == :unverifiable
    assert Anchor.status(discussion, %{}, :listed, false) == :outdated
    assert Anchor.status(discussion, nil, :unread) == :unchecked
  end

  defp anchor(c, path, side, line),
    do: %{
      "revision" => Anchor.revision(c.diff, path),
      "path" => path,
      "side" => side,
      "line" => line
    }

  defp diff(patch),
    do: %Diff{
      path: "/work",
      repo_root: "/work",
      diff: patch,
      truncated: false,
      files: Diff.parse(patch),
      changes: Diff.summarize(patch),
      untracked: :listed
    }
end
