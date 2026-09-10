defmodule RavixWeb.Live.GuardTest do
  @moduledoc """
  When a page may trust the answer it is holding, and when it must ask again.

  These are the rules the LiveView hooks stand on, so they are worth pinning
  down away from a socket. The ones that matter are the negatives: every
  clause of `holds?/1` that returns false is a case where a page goes back to
  the database, and losing one of them is how somebody keeps a screen they
  have been removed from.
  """
  use ExUnit.Case, async: true

  alias Ravix.Hub.Event
  alias RavixWeb.Live.Guard

  defp fresh(opts \\ []) do
    Guard.new(
      Keyword.get(opts, :hash, "hash"),
      Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 1, :hour))
    )
  end

  defp aged(guard, ms), do: %{guard | verified_at_ms: guard.verified_at_ms - ms}

  describe "holds?/1" do
    test "a fresh answer for a live session stands" do
      assert Guard.holds?(fresh())
    end

    test "nothing held stands" do
      refute Guard.holds?(nil)
      # A page with nobody signed in has nothing to hold and asks every time.
      refute Guard.holds?(fresh(hash: nil))
      refute Guard.holds?(fresh(expires_at: nil))
    end

    test "an answer something called stale does not stand" do
      refute Guard.holds?(Guard.stale(fresh()))
    end

    test "an answer stops standing once the session's own expiry has passed" do
      # `expires_at` is written when the session is created and never moved,
      # so the copy a page holds is exact for the life of the row: this is a
      # comparison against the clock and never a query.
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      refute Guard.holds?(fresh(expires_at: past))
    end

    test "an answer stops standing once it is old, whatever else is true" do
      # The backstop for a notice that went missing on a partition.
      guard = fresh()
      assert Guard.holds?(aged(guard, Guard.ttl_ms() - 500))
      refute Guard.holds?(aged(guard, Guard.ttl_ms() + 1))
    end
  end

  describe "observe/3" do
    test "a session ending marks the answer for that session" do
      guard = fresh(hash: "mine")
      refute Guard.holds?(Guard.observe({:session_ended, "mine"}, guard))
      # Somebody else's, which a page is never subscribed to, changes nothing.
      assert Guard.holds?(Guard.observe({:session_ended, "theirs"}, guard))
    end

    test "people and tracks mark a track's answer when they concern that track" do
      guard = fresh()

      for name <- [:people, :tracks] do
        mine = {:hub, Event.new(name, "p1", track_id: "t1")}
        sibling = {:hub, Event.new(name, "p1", track_id: "t2")}
        project = {:hub, Event.new(name, "p1")}

        refute Guard.holds?(Guard.observe(mine, guard, "t1"))
        # An invitation to a branch this page is not showing cannot reach it.
        assert Guard.holds?(Guard.observe(sibling, guard, "t1"))
        # One naming no track is the project's, and might well reach it.
        refute Guard.holds?(Guard.observe(project, guard, "t1"))
      end
    end

    test "a page holding no track answer is untouched by the project's news" do
      # The session hook passes no track: a membership change does not end a
      # session, and re-reading one for it would be work for nothing.
      guard = fresh()

      for name <- Event.names() do
        assert Guard.holds?(Guard.observe({:hub, Event.new(name, "p1", track_id: "t1")}, guard))
      end
    end

    test "the events that cannot take access away leave the answer standing" do
      guard = fresh()

      for name <- [:turn, :queue, :settings, :here] do
        assert Guard.holds?(Guard.observe({:hub, Event.new(name, "p1")}, guard, "t1"))
      end

      assert Guard.holds?(Guard.observe({:transcript, "t1", %{}}, guard, "t1"))
      assert Guard.holds?(Guard.observe(:refresh, guard, "t1"))
    end
  end

  describe "verify/2" do
    test "an answer that stands is handed back without a read" do
      guard = fresh()
      assert {:ok, ^guard} = Guard.verify(guard, "hash")
    end

    test "nothing to ask about is a refusal, not a read" do
      assert :error = Guard.verify(nil, nil)
      assert :error = Guard.verify(fresh(expires_at: nil), nil)
    end
  end
end
