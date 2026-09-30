defmodule Ravix.Tracks.TrackLabelTest do
  use ExUnit.Case, async: true

  alias Ravix.Tracks.Track

  test "a titled track is called by its title, whatever its branch" do
    assert Track.label(%Track{title: "Pull Latest Main", branch: "ravix/crewe"}) ==
             "Pull Latest Main"

    # A person's name is kept as they wrote it, slashes and all.
    assert Track.label(%{title: "feature/login", branch: "ravix/feature-login"}) ==
             "feature/login"
  end

  test "a track still titled with its branch is called by it, read as words" do
    branch = fn b -> Track.label(%Track{title: b, branch: b}) end

    assert branch.("ravix/draft-adr-0009-proposed-workspaces") ==
             "Draft ADR 0009 proposed workspaces"

    assert branch.("ravix/rav-63-track-header-reflow") == "RAV-63 track header reflow"
    assert branch.("ravix/carlisle") == "Carlisle"
    assert branch.("ravix/fix_mcp-api-url") == "Fix MCP API URL"
    # A pull request's own branch keeps its slash; only the namespace goes.
    assert branch.("feature/login-page") == "Feature/login page"
    refute branch.("ravix/verify-dedicated") =~ "ravix/"
  end

  test "with no branch to compare, only the namespace is dropped" do
    assert Track.label(%{title: "ravix/fix-login"}) == "fix-login"
    # Only a leading namespace goes, and never the whole of a name.
    assert Track.label(%{title: "user/ravix/x"}) == "user/ravix/x"
    assert Track.label(%{title: "ravix/"}) == "ravix/"
  end

  test "the tooltip keeps the raw branch under the name" do
    assert Track.tooltip(%Track{title: "Pull Latest Main", branch: "ravix/crewe"}) ==
             "Pull Latest Main\nravix/crewe"

    assert Track.tooltip(%Track{title: "ravix/carlisle", branch: "ravix/carlisle"}) ==
             "Carlisle\nravix/carlisle"

    assert Track.tooltip(%{title: "main", branch: "main"}) == "Main\nmain"
    assert Track.tooltip(%{title: "x-y", branch: nil}) == "x-y"
  end
end
