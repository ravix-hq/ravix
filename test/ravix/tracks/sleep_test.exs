defmodule Ravix.Tracks.SleepTest do
  use Ravix.DataCase, async: true

  alias Ravix.Hub
  alias Ravix.Tracks.{Sleep, Track}
  alias Ravix.Tracks.Transcript.Event

  defp suspended(id), do: stage(id, "sandbox", "done", ~s({"event":"suspended","reason":"idle"}))
  defp started(id), do: stage(id, "turn", "started", nil)

  defp stage(id, stage, state, data),
    do: %{
      "id" => id,
      "kind" => "stage",
      "stage" => stage,
      "state" => state,
      "data" => data,
      "turn_id" => "t#{id}"
    }

  describe "verdict/1" do
    for {name, events, verdict} <- [
          {"nothing about the sandbox", [], nil},
          {"a suspension", [:suspended], :suspended},
          {"a turn after a suspension", [:suspended, :started], :awake},
          {"a suspension after a turn", [:started, :suspended], :suspended},
          {"a reclaim is not sleep", [:reclaimed], nil}
        ] do
      @events events
      @verdict verdict
      test name do
        events =
          @events
          |> Enum.with_index(1)
          |> Enum.map(fn
            {:suspended, i} -> suspended(i)
            {:started, i} -> started(i)
            {:reclaimed, i} -> stage(i, "sandbox", "done", ~s({"event":"reclaimed"}))
          end)

        assert Sleep.verdict(events) == @verdict
        assert Sleep.verdict(Enum.map(events, &Event.from/1)) == @verdict
      end
    end
  end

  describe "observe/3" do
    setup do
      track =
        insert_track(sandbox_layout: :dedicated, sandbox_state: :ready, conversation_id: "conv")

      Hub.subscribe(track.project_id)
      %{track: track}
    end

    test "records sleep and waking once each, and says so on the hub", %{track: track} do
      track_id = track.id
      assert :ok = Sleep.observe(track.id, "conv", [suspended(1)])
      assert %DateTime{} = Repo.get!(Track, track.id).sandbox_suspended_at
      assert_receive {:hub, %Hub.Event{name: :turn, track_id: ^track_id}}

      # A repeat changes nothing and publishes nothing.
      assert :ok = Sleep.observe(track.id, "conv", [suspended(2)])
      refute_receive {:hub, _}, 50

      assert :ok = Sleep.observe(track.id, "conv", [started(3)])
      assert is_nil(Repo.get!(Track, track.id).sandbox_suspended_at)
      assert_receive {:hub, %Hub.Event{name: :turn, track_id: ^track_id}}
    end

    test "a conversation the thread has moved on from is ignored", %{track: track} do
      assert :ok = Sleep.observe(track.id, "replaced", [suspended(1)])
      assert :ok = Sleep.observe("missing-thread", "conv", [suspended(1)])
      assert is_nil(Repo.get!(Track, track.id).sandbox_suspended_at)
      refute_receive {:hub, _}, 50
    end

    test "events that say nothing leave the row alone", %{track: track} do
      assert :ok = Sleep.observe(track.id, "conv", [stage(1, "turn", "done", nil)])
      assert is_nil(Repo.get!(Track, track.id).sandbox_suspended_at)
    end
  end

  test "a shared, closing or closed track never records sleep" do
    for attrs <- [
          [sandbox_layout: :shared],
          [sandbox_layout: :dedicated, sandbox_state: :closing],
          [sandbox_layout: :dedicated, sandbox_state: :ready, closed_at: DateTime.utc_now()]
        ] do
      track = insert_track(attrs)
      assert :ok = Sleep.record(track.id, true)
      assert is_nil(Repo.get!(Track, track.id).sandbox_suspended_at)
    end
  end
end
