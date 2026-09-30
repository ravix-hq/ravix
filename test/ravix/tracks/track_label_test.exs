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

  test "an untitled track is called by its branch, less the shared namespace" do
    assert Track.label(%Track{title: "ravix/fix-login", branch: "ravix/fix-login"}) ==
             "fix-login"

    # Only a leading namespace goes, and never the whole of a name.
    assert Track.label(%{title: "user/ravix/x"}) == "user/ravix/x"
    assert Track.label(%{title: "ravix/"}) == "ravix/"
  end
end
