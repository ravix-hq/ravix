defmodule Ravix.PresenceTest do
  # Presence is two clocks with opposite requirements, and every test here is
  # about one of them being wrong in the direction that matters: a watcher
  # who vanishes too eagerly is a colleague who disappeared while still
  # reading; a typist who lingers is "Ana is typing..." over an empty chair,
  # which is the one indicator people actually wait on.
  use ExUnit.Case, async: true

  alias Ravix.Accounts.User
  alias Ravix.Hub
  alias Ravix.Hub.Event
  alias Ravix.Presence

  setup_all do
    Ravix.TracksBoot.ensure_running()
    :ok
  end

  setup do
    n = System.unique_integer([:positive])
    track = "t-#{n}"
    project = "p-#{n}"
    Hub.subscribe(project)
    {:ok, track: track, project: project}
  end

  defp ana, do: %User{id: "u-ana", login: "ana", name: "Ana", avatar_url: nil}
  defp bo, do: %User{id: "u-bo", login: "bo", name: "Bo", avatar_url: nil}

  defp logins(present), do: Enum.map(present, & &1.login)

  test "a beat puts somebody in the room, and everybody on the project hears", ctx do
    assert ["ana"] == ctx.track |> Presence.beat(ctx.project, ana(), false) |> logins()
    assert ["ana"] == ctx.track |> Presence.present() |> logins()
    track = ctx.track

    assert_receive {:hub,
                    %Event{
                      name: :here,
                      track_id: ^track,
                      present: [%{login: "ana", typing: false}]
                    }}
  end

  test "an empty track has nobody in it" do
    assert Presence.present("never-touched") == []
  end

  test "two people are both there, in a stable order", ctx do
    # Sorted by login rather than by arrival, so the row does not reshuffle
    # every time somebody's heartbeat lands.
    other = spawn_watcher(ctx, bo())
    Presence.beat(ctx.track, ctx.project, ana(), false)
    assert ["ana", "bo"] == ctx.track |> Presence.present() |> logins()
    send(other, :leave)
  end

  test "watching is the process: a page that dies is gone, without a lease to wait out", ctx do
    other = spawn_watcher(ctx, bo())
    assert ["bo"] == ctx.track |> Presence.present() |> logins()
    ref = Process.monitor(other)
    Process.exit(other, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}
    track = ctx.track
    assert_receive {:hub, %Event{name: :here, track_id: ^track, present: []}}, 1_000
    assert Presence.present(ctx.track) == []
  end

  test "typing expires long before watching does", ctx do
    Presence.beat(ctx.track, ctx.project, ana(), true)
    now = System.system_time(:millisecond)
    assert [%{typing: true}] = Presence.present(ctx.track, now)
    # Three seconds later they are still in the room and no longer mid-sentence.
    assert [%{typing: false, login: "ana"}] =
             Presence.present(ctx.track, now + Presence.typing_ttl_ms() + 1)
  end

  test "a plain heartbeat does not cancel a typing pulse", ctx do
    # The composer pings on a timer *and* on keystrokes. If the slower one
    # arriving second cleared the flag, the indicator would blink off between
    # words, which is exactly when it should be on.
    Presence.beat(ctx.track, ctx.project, ana(), true)
    assert [%{typing: true}] = Presence.beat(ctx.track, ctx.project, ana(), false)
  end

  test "a typing pulse refreshes the window rather than extending it forever", ctx do
    Presence.beat(ctx.track, ctx.project, ana(), true)
    first = System.system_time(:millisecond)
    Presence.beat(ctx.track, ctx.project, ana(), true)
    ttl = Presence.typing_ttl_ms()
    assert [%{typing: true}] = Presence.present(ctx.track, first + ttl - 500)
    assert [%{typing: false}] = Presence.present(ctx.track, first + ttl * 2 + 1)
  end

  test "leaving is immediate, and only removes the one who left", ctx do
    other = spawn_watcher(ctx, bo())
    Presence.beat(ctx.track, ctx.project, ana(), false)
    :ok = Presence.leave(ctx.track, "u-ana")
    assert ["bo"] == ctx.track |> Presence.present() |> logins()
    track = ctx.track

    assert_receive {:hub, %Event{name: :here, track_id: ^track, present: [%{login: "bo"}]}},
                   1_000

    send(other, :leave)
  end

  test "leaving a track you are not in changes nothing", ctx do
    Presence.beat(ctx.track, ctx.project, ana(), false)
    :ok = Presence.leave(ctx.track, "u-nobody")
    assert ["ana"] == ctx.track |> Presence.present() |> logins()
  end

  test "presence is per track, not per project", ctx do
    Presence.beat(ctx.track, ctx.project, ana(), false)
    other = spawn_watcher(%{ctx | track: ctx.track <> "-2"}, bo())
    assert ["ana"] == ctx.track |> Presence.present() |> logins()
    assert ["bo"] == (ctx.track <> "-2") |> Presence.present() |> logins()
    send(other, :leave)
  end

  test "a lapsed typing pulse is announced without anybody asking", ctx do
    # The pulse lands, and three seconds later a frame goes out saying it
    # stopped, even though no request arrived to say so.
    Presence.beat(ctx.track, ctx.project, ana(), true)
    track = ctx.track
    assert_receive {:hub, %Event{name: :here, track_id: ^track, present: [%{typing: true}]}}

    assert_receive {:hub, %Event{name: :here, track_id: ^track, present: [%{typing: false}]}},
                   Presence.typing_ttl_ms() + 1_000
  end

  # Another page: a process that beats once and stays until told to leave.
  defp spawn_watcher(ctx, user) do
    parent = self()

    pid =
      spawn(fn ->
        Presence.beat(ctx.track, ctx.project, user, false)
        send(parent, {:watching, self()})

        receive do
          :leave -> Presence.leave(ctx.track, user.id)
        end
      end)

    assert_receive {:watching, ^pid}
    pid
  end
end
