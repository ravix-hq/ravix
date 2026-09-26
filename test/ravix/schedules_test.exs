defmodule Ravix.SchedulesTest do
  use Ravix.DataCase, async: true
  import Mimic
  alias Ecto.Adapters.SQL.Sandbox
  alias Ravix.{Repo, Schedules, Tracks}
  alias Ravix.Schedules.{Runner, Schedule, Store}

  setup :verify_on_exit!

  defp attrs,
    do: %{
      "name" => "Weekly review",
      "prompt" => "Review recent changes",
      "frequency" => "weekly",
      "time" => "09:30",
      "weekday" => "1"
    }

  test "next occurrence is strictly in the future, including week and year boundaries" do
    now = ~U[2026-12-31 09:30:00.000000Z]
    row = %Schedule{frequency: :hourly, time: ~T[09:30:00]}
    assert Schedule.next_run(row, now) == ~U[2026-12-31 10:30:00.000000Z]

    assert Schedule.next_run(%{row | frequency: :daily}, ~U[2026-12-31 23:00:00.000000Z]) ==
             ~U[2027-01-01 09:30:00.000000Z]

    assert Schedule.next_run(%{row | frequency: :weekly, weekday: 4}, now) ==
             ~U[2027-01-07 09:30:00.000000Z]

    assert Schedule.next_run(%{row | frequency: :weekly, weekday: 5}, now) ==
             ~U[2027-01-01 09:30:00.000000Z]
  end

  test "schedules are personal and require whole-project membership" do
    owner = insert_user()
    project = insert_project(user: owner)
    member = insert_user()
    insert_project_member(project, member)
    guest = insert_user()
    track = insert_track(project: project)
    insert_track_member(track, guest)
    assert {:error, :not_found} = Schedules.create(guest, project.id, attrs())

    assert {:ok, row} =
             Schedules.create(member, project.id, Map.put(attrs(), "user_id", owner.id))

    assert row.user_id == member.id
    assert Schedules.list(owner) == []
    assert {:error, :not_found} = Schedules.update(owner, row.id, %{enabled: false})
    assert {:error, :not_found} = Schedules.delete(guest, row.id)
    assert {:ok, _} = Schedules.update(member, row.id, %{enabled: false})
    assert {:ok, _} = Schedules.delete(member, row.id)
  end

  test "invalid schedules never persist" do
    user = insert_user()
    project = insert_project(user: user)

    for invalid <- [
          %{"prompt" => "  "},
          %{"frequency" => "minutely"},
          %{"time" => "25:99"},
          %{"weekday" => "8"}
        ] do
      assert {:error, %Ecto.Changeset{}} =
               Schedules.create(user, project.id, Map.merge(attrs(), invalid))
    end

    assert Schedules.list(user) == []
  end

  test "clearing required fields on an existing schedule returns errors without losing its prompt" do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, row} = Schedules.create(user, project.id, attrs())

    assert {:error, %Ecto.Changeset{}} =
             Schedules.update(user, row.id, %{"prompt" => "", "name" => ""})

    assert {:ok, %{prompt: "Review recent changes"}} = Schedules.get(user, row.id)
    assert {:error, :not_found} = Schedules.get(user, nil)
  end

  test "durable claims coalesce missed occurrences and cannot be claimed twice" do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, row} = Schedules.create(user, project.id, attrs())
    now = DateTime.add(row.next_run_at, 30, :day)
    assert {:ok, claimed} = Store.claim(row.id, now)
    assert claimed.last_run_at == now
    assert DateTime.compare(claimed.next_run_at, now) == :gt
    assert {:ok, nil} = Store.claim(row.id, now)
    {:ok, _} = Schedules.update(user, row.id, %{enabled: false})
    assert {:ok, nil} = Store.claim(row.id, DateTime.add(now, 30, :day))
  end

  test "run opens a distinct track and queues exactly one prompt" do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, row} = Schedules.create(user, project.id, attrs())
    track = insert_track(project: project)
    parent = self()

    expect(Tracks, :open, fn actor, project_id, attrs ->
      assert actor.id == user.id
      assert project_id == project.id
      assert Ravix.Ids.valid_branch_name?(attrs["title"])
      send(parent, {:opened, attrs["title"]})
      {:ok, %{id: track.id}}
    end)

    expect(Tracks, :prompt, fn actor, id, payload ->
      assert actor.id == user.id
      assert id == track.id
      assert payload["prompt"] == row.prompt
      assert payload["request_id"] =~ row.id
      {:ok, %{}}
    end)

    Runner.run(row.id, row.next_run_at)
    Runner.run(row.id, row.next_run_at)
    assert_received {:opened, _}
    assert {:ok, updated} = Schedules.get(user, row.id)
    assert updated.last_track_id == track.id
    assert updated.last_status == "Prompt queued"
  end

  test "revoked project membership prevents a scheduled dispatch" do
    owner = insert_user()
    project = insert_project(user: owner)
    member = insert_user()
    membership = insert_project_member(project, member)
    {:ok, row} = Schedules.create(member, project.id, attrs())
    Repo.delete!(membership)
    reject(&Tracks.open/3)
    Runner.run(row.id, row.next_run_at)
    assert Schedules.list(member) == []
    assert Repo.get!(Schedule, row.id).last_status =~ "Could not open track"
  end

  test "a failed queue keeps the track link and is not retried within the occurrence" do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, row} = Schedules.create(user, project.id, attrs())
    track = insert_track(project: project)
    expect(Tracks, :open, fn _, _, _ -> {:ok, %{id: track.id}} end)
    expect(Tracks, :prompt, fn _, _, _ -> {:error, :unavailable} end)
    Runner.run(row.id, row.next_run_at)
    Runner.run(row.id, row.next_run_at)
    {:ok, updated} = Schedules.get(user, row.id)
    assert updated.last_status == "Could not queue prompt"
    assert updated.last_track_id == track.id
  end

  test "the supervised timer dispatches due work and leaves future schedules alone" do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, row} = Schedules.create(user, project.id, attrs())

    row
    |> Ecto.Changeset.change(next_run_at: DateTime.add(DateTime.utc_now(), -60))
    |> Repo.update!()

    {:ok, future} = Schedules.create(user, project.id, attrs())
    expect(Tracks, :open, fn _, _, _ -> {:error, :unavailable} end)
    server = start_supervised!({Ravix.Schedules.Server, interval: false})
    Sandbox.allow(Repo, self(), server)
    allow(Tracks, self(), server)
    send(server, :tick)
    assert :sys.get_state(server) == false
    assert Repo.get!(Schedule, row.id).last_status =~ "Could not open track"
    assert Repo.get!(Schedule, future.id).last_run_at == nil
  end

  test "a crash is recorded without replaying the claimed occurrence" do
    user = insert_user()
    project = insert_project(user: user)
    {:ok, row} = Schedules.create(user, project.id, attrs())
    expect(Tracks, :open, fn _, _, _ -> raise "provider interrupted" end)
    Runner.run(row.id, row.next_run_at)
    Runner.run(row.id, row.next_run_at)

    assert {:ok, %{last_status: "Dispatch interrupted; check tracks before trying again"}} =
             Schedules.get(user, row.id)
  end
end
