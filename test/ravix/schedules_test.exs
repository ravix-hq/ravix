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

  describe "local-time schedules" do
    defp daily(time, zone), do: %Schedule{frequency: :daily, time: time, timezone: zone}

    test "a 09:00 daily schedule created in Asia/Kolkata stores that zone and runs at 03:30 UTC" do
      user = insert_user()
      project = insert_project(user: user)

      {:ok, row} =
        Schedules.create(
          user,
          project.id,
          Map.merge(attrs(), %{
            "frequency" => "daily",
            "time" => "09:00",
            "timezone" => "Asia/Kolkata"
          })
        )

      assert {:ok, %{timezone: "Asia/Kolkata"}} = Schedules.get(user, row.id)
      assert {row.next_run_at.hour, row.next_run_at.minute} == {3, 30}

      assert Schedule.next_run(row, ~U[2026-06-01 03:30:00.000000Z]) ==
               ~U[2026-06-02 03:30:00.000000Z]
    end

    test "America/New_York stays at 9:00 local across both DST changes" do
      row = daily(~T[09:00:00], "America/New_York")

      # 2026-03-08: EST (UTC-5) becomes EDT (UTC-4).
      assert Schedule.next_run(row, ~U[2026-03-07 14:00:00.000000Z]) ==
               ~U[2026-03-08 13:00:00.000000Z]

      # 2026-11-01: EDT becomes EST.
      assert Schedule.next_run(row, ~U[2026-10-31 13:00:00.000000Z]) ==
               ~U[2026-11-01 14:00:00.000000Z]

      weekly = %{row | frequency: :weekly, weekday: 1}

      assert Schedule.next_run(weekly, ~U[2026-03-02 14:00:00.000000Z]) ==
               ~U[2026-03-09 13:00:00.000000Z]

      # Sunday 2026-11-01 is the change; the Monday before is EDT, after is EST.
      assert Schedule.next_run(weekly, ~U[2026-10-26 13:00:00.000000Z]) ==
               ~U[2026-11-02 14:00:00.000000Z]
    end

    test "a time inside the spring-forward gap runs at the first instant after it" do
      row = daily(~T[02:30:00], "America/New_York")

      # 02:30 does not exist on 2026-03-08; 03:00 EDT is the next valid instant.
      assert Schedule.next_run(row, ~U[2026-03-07 08:00:00.000000Z]) ==
               ~U[2026-03-08 07:00:00.000000Z]

      assert Schedule.next_run(row, ~U[2026-03-08 07:00:00.000000Z]) ==
               ~U[2026-03-09 06:30:00.000000Z]
    end

    test "a time inside the autumn fold runs once, at its first instance" do
      row = daily(~T[01:30:00], "America/New_York")

      # 01:30 happens at 05:30Z (EDT) and again at 06:30Z (EST) on 2026-11-01.
      assert Schedule.next_run(row, ~U[2026-10-31 12:00:00.000000Z]) ==
               ~U[2026-11-01 05:30:00.000000Z]

      for now <- [~U[2026-11-01 05:30:00.000000Z], ~U[2026-11-01 06:00:00.000000Z]] do
        assert Schedule.next_run(row, now) == ~U[2026-11-02 06:30:00.000000Z]
      end
    end

    test "hourly runs at the chosen local minute" do
      row = %Schedule{frequency: :hourly, time: ~T[09:15:00], timezone: "Asia/Kolkata"}

      assert Schedule.next_run(row, ~U[2026-01-01 00:00:00.000000Z]) ==
               ~U[2026-01-01 00:45:00.000000Z]

      assert Schedule.next_run(row, ~U[2026-01-01 00:45:00.000000Z]) ==
               ~U[2026-01-01 01:45:00.000000Z]
    end

    test "an invalid zone falls back to UTC without creating atoms" do
      user = insert_user()
      project = insert_project(user: user)
      assert Schedules.timezone("Europe/Berlin") == "Europe/Berlin"
      assert Schedules.timezone(" Asia/Kolkata ") == "Asia/Kolkata"

      unknown = "Nowhere/Zone#{System.unique_integer([:positive])}"
      long = String.duplicate("A/", 100)

      for value <- [unknown, "", "  ", nil, 42, %{}, "UTC; DROP", long] do
        assert Schedules.timezone(value) == "Etc/UTC"
      end

      # Asked of the words themselves rather than of
      # `:erlang.system_info(:atom_count)`, which is the whole VM's: every other
      # async test runs beside this one, and a module loading or a Mimic copy
      # between the before and the after failed a lookup that made no atom.
      for word <- [unknown, "UTC; DROP", long] do
        assert_raise ArgumentError, fn -> String.to_existing_atom(word) end
      end

      for zone <- [unknown, "", nil] do
        {:ok, row} = Schedules.create(user, project.id, Map.put(attrs(), "timezone", zone))
        assert row.timezone == "Etc/UTC"
      end
    end

    test "a stored zone the database no longer knows claims on UTC without stalling the runner" do
      user = insert_user()
      project = insert_project(user: user)
      prompt = "Secret prompt text #{System.unique_integer([:positive])}"

      {:ok, bad} =
        Schedules.create(user, project.id, Map.merge(attrs(), %{"prompt" => prompt}))

      {:ok, good} = Schedules.create(user, project.id, attrs())
      now = DateTime.add(good.next_run_at, 30, :day)

      # Bypasses the changeset, as a tz release that drops a zone would.
      Repo.update_all(from(s in Schedule, where: s.id == ^bad.id), set: [timezone: "Gone/Zone"])

      stub(Ravix.Accounts.Access, :project_access, fn _, _ -> {:error, :not_found} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Runner.tick(now) == :ok
        end)

      assert log =~ bad.id
      assert log =~ "Gone/Zone"
      refute log =~ prompt

      # Access is stubbed shut so dispatch finishes at once; read the rows directly.
      for id <- [bad.id, good.id] do
        row = Repo.get!(Schedule, id)
        assert row.last_run_at == now
        assert DateTime.compare(row.next_run_at, now) == :gt
      end

      claimed = Repo.get!(Schedule, bad.id)
      assert claimed.next_run_at == Schedule.next_run(%{claimed | timezone: "Etc/UTC"}, now)
    end

    test "editing keeps the stored zone unless the change names one" do
      user = insert_user()
      project = insert_project(user: user)

      {:ok, row} =
        Schedules.create(user, project.id, Map.put(attrs(), "timezone", "America/New_York"))

      assert {:ok, %{timezone: "America/New_York"}} =
               Schedules.update(user, row.id, %{"prompt" => "Something else"})

      assert {:ok, %{timezone: "America/New_York"}} =
               Schedules.update(user, row.id, %{enabled: false})

      assert {:ok, %{timezone: "Asia/Kolkata"} = moved} =
               Schedules.update(user, row.id, %{"timezone" => "Asia/Kolkata", "enabled" => "true"})

      assert {moved.next_run_at.hour, moved.next_run_at.minute} == {4, 0}
    end

    test "rows written without a zone keep their UTC times" do
      user = insert_user()
      project = insert_project(user: user)
      id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      # What the previous release inserts: no timezone column in the row.
      Repo.insert_all(
        "schedules",
        [
          %{
            id: id,
            user_id: user.id,
            project_id: project.id,
            name: "Old",
            prompt: "Check",
            frequency: "daily",
            time: ~T[09:30:00],
            weekday: 1,
            next_run_at: now,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: "ravix"
      )

      assert {:ok, %{timezone: "Etc/UTC"} = row} = Schedules.get(user, id)

      assert Schedule.next_run(row, ~U[2026-03-08 12:00:00.000000Z]) ==
               ~U[2026-03-09 09:30:00.000000Z]
    end
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
