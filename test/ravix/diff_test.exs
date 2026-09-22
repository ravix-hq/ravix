defmodule Ravix.Tracks.DiffTest do
  use ExUnit.Case, async: true
  alias Ravix.Tracks.Diff
  @patch File.read!("test/fixtures/diff/files.patch")

  test "real git output preserves coordinates, metadata, paths and content" do
    files = Map.new(Diff.parse(@patch), &{&1.change.path, &1})
    assert files["added.txt"].change.status == :added
    assert files["added.txt"].change.added == 1
    assert hd(hd(files["added.txt"].hunks).lines).text == "+++ content"
    assert files["deleted.txt"].change.status == :deleted
    assert files["new name.txt"].old_path == "old name.txt"
    assert files["new name.txt"].change.status == :renamed
    assert files["binary.dat"].binary
    assert files["mode.sh"].metadata == ["old mode 100644", "new mode 100755"]
    assert files["mode.sh"].hunks == []
    assert files["quote\tname.txt"].change.added == 1
    assert Enum.all?(hd(files["nonewline.txt"].hunks).lines, & &1.no_newline)
    hunk = hd(files["space name.txt"].hunks)
    assert {hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count} == {1, 3, 1, 3}

    assert Enum.map(hunk.lines, &{&1.kind, &1.old, &1.new}) ==
             [{:context, 1, 1}, {:del, 2, nil}, {:add, nil, 2}, {:context, 3, 3}]

    assert Diff.summarize(@patch) == Enum.map(Diff.parse(@patch), & &1.change)
  end

  test "Git C-quoted paths decode octal UTF-8 and escaped control characters" do
    paths =
      "test/fixtures/diff/quoted.patch"
      |> File.read!()
      |> Diff.parse()
      |> Enum.map(& &1.change.path)

    assert Enum.sort(paths) ==
             Enum.sort(["café.txt", "quoted\"", "back\\slash", "line\nbreak", "carriage\rreturn"])
  end

  test "truncation marks only the last available section and retains partial lines" do
    patch = @patch |> String.split("+<script>") |> hd()
    files = Diff.parse(patch <> "+cut off", true)
    assert List.last(files).partial
    refute Enum.any?(Enum.drop(files, -1), & &1.partial)
    assert List.last(hd(List.last(files).hunks).lines).text == "cut off"
    assert Diff.parse("") == []
    assert Diff.parse("preamble\n") == []
  end

  test "multiple hunks reset their line numbers and default omitted counts to one" do
    [file] = Diff.parse("diff --git a/a b/a\n@@ -1 +1 @@\n-a\n+b\n@@ -9,0 +10,2 @@\n+c\n+d\n")
    assert Enum.map(file.hunks, &{&1.old_count, &1.new_count}) == [{1, 1}, {0, 2}]
    assert Enum.map(List.last(file.hunks).lines, & &1.new) == [10, 11]
  end
end
