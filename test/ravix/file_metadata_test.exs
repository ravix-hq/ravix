defmodule Ravix.FileMetadataTest do
  use ExUnit.Case, async: true
  alias Ravix.Tracks.Files

  setup do
    base = Path.expand("tmp/file-metadata-#{System.unique_integer([:positive])}")
    root = Path.join(base, "repo")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(base) end)
    {_, 0} = System.cmd("git", ["init", "-q", root])
    %{root: root, base: base}
  end

  test "Git rules include nested negation, tracked exceptions and literal filenames", %{
    root: root
  } do
    File.write!(Path.join(root, ".gitignore"), "_build/\n*.log\n!keep.log\n")
    File.mkdir_p!(Path.join(root, "_build"))

    for name <- [
          "debug.log",
          "keep.log",
          "tracked.log",
          "$(touch injected).log",
          "line\nbreak.log"
        ] do
      File.write!(Path.join(root, name), "")
    end

    {_, 0} = System.cmd("git", ["-C", root, "add", "-f", "tracked.log"])

    listing =
      listing(root, [
        "_build",
        "debug.log",
        "keep.log",
        "tracked.log",
        "$(touch injected).log",
        "line\nbreak.log"
      ])

    result = metadata(root, listing)
    assert result.ignore_available?

    assert Enum.filter(result.entries, & &1.ignored?) |> Enum.map(& &1.name) == [
             "_build",
             "debug.log",
             "$(touch injected).log",
             "line\nbreak.log"
           ]

    refute File.exists?(Path.join(root, "injected"))
    File.mkdir_p!(Path.join(root, "nested"))
    File.write!(Path.join(root, "nested/.gitignore"), "!debug.log\n")
    File.write!(Path.join(root, "nested/debug.log"), "")

    assert [%{ignored?: false}] =
             metadata(root, listing(Path.join(root, "nested"), ["debug.log"])).entries
  end

  test "links report their targets without following internal, external, broken or cyclic links",
       %{root: root, base: base} do
    File.mkdir_p!(Path.join(root, "skills"))
    File.mkdir_p!(Path.join(base, "outside"))

    for {name, target} <- [
          {"internal", "skills"},
          {"external", "../outside"},
          {"broken", "missing"},
          {"loop", "loop"}
        ] do
      File.ln_s!(target, Path.join(root, name))
    end

    result = metadata(root, listing(root, ["internal", "external", "broken", "loop"]))

    assert Enum.map(result.entries, &{&1.type, &1.target}) == [
             {"symlink", "skills"},
             {"symlink", "../outside"},
             {"symlink", "missing"},
             {"symlink", "loop"}
           ]

    escaped = listing(Path.join(root, "external"), ["secret"])
    assert metadata(root, escaped) == escaped
  end

  test "missing metadata and non-repositories preserve the listing", %{base: base} do
    listing = listing(base, ["repo"])
    refute metadata(base, listing).ignore_available?
    assert Files.with_metadata(listing, {:error, :unavailable}) == listing
    assert Files.with_metadata(listing, {:ok, %{code: 0, stdout: "bad json"}}) == listing
    assert Files.with_metadata(listing, {:ok, %{code: 0, stdout: "{}"}}) == listing
  end

  defp listing(path, names) do
    %Files.Listing{
      path: path,
      truncated: false,
      entries: Enum.map(names, &%Files.Entry{name: &1, type: "file", size: 0})
    }
  end

  defp metadata(root, listing) do
    {output, code} =
      System.cmd("sh", ["-c", Files.metadata_command(root, listing)],
        cd: root,
        stderr_to_stdout: true
      )

    Files.with_metadata(listing, {:ok, %{code: code, stdout: output}})
  end
end
