defmodule Ravix.Previews.WakeTest do
  @moduledoc """
  RAV-40: a preview started on a sleeping track wakes the machine first, says
  so as it goes, joins a start already under way, and tells whoever follows
  the track about every change --- without telling anybody who may not look.

  The machine is the fixture's scripted Sprites provider: `Ravix.Tracks.wake/2`
  probes it with `Sprites.exec/4`, which is the provider boundary this stubs.
  """
  use Ravix.DataCase, async: true, group: :preview_ports
  use Mimic

  import Ravix.PreviewsFixture

  alias Ravix.Previews
  alias Ravix.Previews.{Lifecycle, Reconciler, Server, Store}
  alias Ravix.Tracks.Track

  setup do
    start_tree()
    provider = start_provider()
    stub_provider(provider)
    owner = insert_user()
    project = insert_project(user: owner)

    track =
      insert_track(
        project: project,
        conversation_id: "c1",
        sandbox_layout: :dedicated,
        sandbox_id: "s1"
      )

    {_token, session} = insert_session(owner)

    insert_preview_default(project,
      config: %{"directory" => ".", "command" => "npm run dev", "readinessPath" => "/"}
    )

    on_exit(fn -> Server.stop(track.id) end)
    %{p: provider, owner: owner, project: project, track: track, session: session}
  end

  defp asleep!(track) do
    track
    |> Ecto.Changeset.change(sandbox_suspended_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp suspended_at(track), do: Repo.get!(Track, track.id).sandbox_suspended_at

  # Every message until the preview says `state`, or a flunk.
  defp follow_until(user, track_id, state) do
    receive do
      {:preview, ^track_id} ->
        case Previews.status(user, track_id) do
          {:ok, %{state: ^state} = view} -> view
          _ -> follow_until(user, track_id, state)
        end
    after
      2_000 -> flunk("the preview never said #{state}")
    end
  end

  test "opening on an asleep machine wakes it, says waking, then starting, then ready", ctx do
    asleep!(ctx.track)
    assert :ok = Previews.subscribe(ctx.owner, ctx.track.id)
    me = self()

    # Held until the test has seen the page's first answer, so "waking" is
    # observed rather than raced past.
    stub(Ravix.Sprites, :reachable?, fn _cfg, "s1" ->
      send(me, {:waking, self()})
      receive do: (:wake -> true)
    end)

    assert {:ok, %{state: :waking, open_url: url}} =
             Previews.open(ctx.owner, ctx.track.id, ctx.session.token_hash)

    assert is_binary(url)
    assert_receive {:preview, _}
    assert {:ok, %{state: :waking}} = Previews.status(ctx.owner, ctx.track.id)
    assert suspended_at(ctx.track)

    assert_receive {:waking, probe}
    # The reconciler's tick lands during the wake. The start is its asker's:
    # ensuring it from here would define the service now, and the asker's own
    # start would then run it a second time behind that one.
    Reconciler.tick()
    assert state(ctx.p).creates == 0
    send(probe, :wake)

    assert %{state: :ready} = follow_until(ctx.owner, ctx.track.id, :ready)
    # The wake went through `Tracks.wake/2`, which cleared the mark the header
    # and the dock read.
    assert is_nil(suspended_at(ctx.track))
    await_background()
    assert state(ctx.p).creates == 1
  end

  test "a machine that will not wake fails the start with that reason", ctx do
    asleep!(ctx.track)
    assert :ok = Previews.subscribe(ctx.owner, ctx.track.id)
    stub(Ravix.Sprites, :reachable?, fn _cfg, "s1" -> false end)

    assert {:ok, %{state: :waking}} = Previews.run(ctx.owner, ctx.track.id)
    view = follow_until(ctx.owner, ctx.track.id, :failed)
    assert view.error =~ "Machine couldn't wake: This track's machine did not wake."
    assert Store.get(ctx.track.id).desired == :stopped
    await_background()
    # Nothing was defined on a machine that never answered, and it still
    # reads asleep, which is what it is.
    assert state(ctx.p).creates == 0
    assert suspended_at(ctx.track)
  end

  test "a wake that fails after a Stop leaves the stop alone", ctx do
    asleep!(ctx.track)
    me = self()

    stub(Ravix.Sprites, :reachable?, fn _cfg, "s1" ->
      send(me, {:waking, self()})
      receive do: (:answer -> false)
    end)

    assert {:ok, %{state: :waking}} = Previews.run(ctx.owner, ctx.track.id)
    assert_receive {:waking, probe}
    assert {:ok, %{state: :stopped}} = Previews.stop(ctx.owner, ctx.track.id)
    send(probe, :answer)
    await_background()

    assert {:ok, %{state: :stopped, error: nil}} = Previews.status(ctx.owner, ctx.track.id)
  end

  test "a wake that raises still settles the start instead of leaving it waking", ctx do
    asleep!(ctx.track)
    assert :ok = Previews.subscribe(ctx.owner, ctx.track.id)
    stub(Ravix.Sprites, :reachable?, fn _cfg, _sprite -> raise "tunnel closed" end)

    assert {:ok, %{state: :waking}} = Previews.run(ctx.owner, ctx.track.id)

    assert %{error: "Machine couldn't wake: tunnel closed"} =
             follow_until(ctx.owner, ctx.track.id, :failed)

    await_background()
  end

  test "an awake machine is not probed before the start", ctx do
    reject(&Ravix.Tracks.wake/2)
    assert {:ok, %{state: :starting}} = Previews.run(ctx.owner, ctx.track.id)
    await_background()
    assert {:ok, %{state: :ready}} = Previews.status(ctx.owner, ctx.track.id)
  end

  test "a second click while a start is under way joins it rather than starting again", ctx do
    put(ctx.p, :barrier, true)

    assert {:ok, %{state: :starting}} =
             Previews.open(ctx.owner, ctx.track.id, ctx.session.token_hash)

    await(ctx.p, &(&1.creates == 1))
    generation = Store.get(ctx.track.id).generation

    assert {:ok, %{state: :starting, open_url: url}} =
             Previews.open(ctx.owner, ctx.track.id, ctx.session.token_hash)

    assert is_binary(url)
    assert {:ok, %{state: :starting}} = Previews.run(ctx.owner, ctx.track.id)
    assert Store.get(ctx.track.id).generation == generation

    put(ctx.p, :barrier, false)
    await_background()
    assert {:ok, %{state: :ready}} = Previews.status(ctx.owner, ctx.track.id)
    assert state(ctx.p).creates == 1
  end

  test "the server answers a joined start with the result of the one already running", ctx do
    put(ctx.p, :barrier, true)
    assert {:ok, {:started, generation}} = Lifecycle.begin(ctx.track.id)
    assert {:ok, {:joined, ^generation}} = Lifecycle.begin(ctx.track.id)

    first = Task.async(fn -> Lifecycle.carry_out(ctx.track.id, generation, :start) end)
    await(ctx.p, &(&1.creates == 1))
    second = Task.async(fn -> Lifecycle.carry_out(ctx.track.id, generation, :start) end)
    # Queued behind the first, the second would run once the barrier lifts
    # and find the service already defined; joined, it is answered with the
    # first's result and nothing runs after it.
    await(ctx.p, fn _ -> Server.busy?(ctx.track.id) end)
    put(ctx.p, :barrier, false)

    assert [:ok, :ok] = Task.await_many([first, second])
    refute Server.busy?(ctx.track.id)
    assert state(ctx.p).creates == 1
    assert Enum.count(state(ctx.p).execs, &match?(["sh", "-lc", _], &1)) == 1
  end

  test "a restart never joins", ctx do
    assert {:ok, {:started, generation}} = Lifecycle.begin(ctx.track.id)
    assert {:ok, {:started, next}} = Lifecycle.begin(ctx.track.id, :restart)
    assert next == generation + 1
  end

  test "a timeout reaches the follower with its reason", ctx do
    assert :ok = Previews.subscribe(ctx.owner, ctx.track.id)
    put(ctx.p, :ready, false)

    assert {:ok, %{state: :starting}} = Previews.run(ctx.owner, ctx.track.id)
    view = follow_until(ctx.owner, ctx.track.id, :failed)
    assert view.error =~ "Nothing answered on / within 60s"
    await_background()
  end

  test "no run script is a failure that says so", ctx do
    Repo.delete_all(Ravix.Previews.PreviewDefault)
    assert :ok = Previews.subscribe(ctx.owner, ctx.track.id)
    assert {:ok, %{state: :starting}} = Previews.run(ctx.owner, ctx.track.id)

    assert %{error: "No run script configured" <> _} =
             follow_until(ctx.owner, ctx.track.id, :failed)

    await_background()
  end

  test "a Read member can neither start nor wake a preview", ctx do
    asleep!(ctx.track)
    reader = insert_user()
    insert_track_member(ctx.track, reader, role: :read)
    {_token, session} = insert_session(reader)
    reject(&Ravix.Tracks.wake/2)
    reject(&Lifecycle.begin/2)

    assert {:error, {:forbidden, _}} = Previews.open(reader, ctx.track.id, session.token_hash)
    assert {:error, _} = Previews.run(reader, ctx.track.id)
    assert {:error, _} = Previews.run(reader, ctx.track.id, :restart)
    assert {:error, _} = Previews.restart(reader, ctx.track.id, session.token_hash)
    assert Store.get(ctx.track.id) == nil or Store.get(ctx.track.id).desired == :stopped
    assert suspended_at(ctx.track)

    # Reading is theirs, and so is following.
    assert :ok = Previews.subscribe(reader, ctx.track.id)
    assert {:ok, %{state: :stopped}} = Previews.status(reader, ctx.track.id)
  end

  test "somebody who may not see the track cannot follow it", ctx do
    stranger = insert_user()
    insert_project(user: stranger)
    assert {:error, :not_found} = Previews.subscribe(stranger, ctx.track.id)

    ctx.track |> Ecto.Changeset.change(closed_at: DateTime.utc_now()) |> Repo.update!()
    assert {:error, {:conflict, "closed_track", _}} = Previews.subscribe(ctx.owner, ctx.track.id)
  end

  test "a tick that finds the preview as it was publishes nothing", ctx do
    assert {:ok, %{state: :starting}} = Previews.run(ctx.owner, ctx.track.id)
    await_background()
    assert {:ok, %{state: :ready}} = Previews.status(ctx.owner, ctx.track.id)
    row = Store.get(ctx.track.id)
    assert :ok = Previews.subscribe(ctx.owner, ctx.track.id)

    # The lease `run/3` took is live, so the reconciler ensures the running
    # preview again: it probes, finds it ready, and would write `:ready` onto
    # a row that already says so. Every page following the track used to
    # hear that and read the preview again, every fifteen seconds.
    assert Reconciler.decide(row, ctx.track, ctx.project, now(ctx.p)) == :ensure
    Reconciler.tick()
    await_background()

    assert Store.get(ctx.track.id) == row
    refute_received {:preview, _}
  end

  test "a stop is told to followers too", ctx do
    assert {:ok, %{state: :starting}} = Previews.run(ctx.owner, ctx.track.id)
    await_background()
    assert :ok = Previews.subscribe(ctx.owner, ctx.track.id)
    assert {:ok, %{state: :stopped}} = Previews.stop(ctx.owner, ctx.track.id)
    track_id = ctx.track.id
    assert_receive {:preview, ^track_id}
    Previews.unsubscribe(track_id)
  end
end
