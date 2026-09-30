defmodule Ravix.TracksWakeTest do
  # `Tracks.wake/2`, the inspector's Wake. The machine is stubbed at the
  # terminal's probe and the provider boundary; access is the real door.
  use Ravix.DataCase, async: true

  import Mimic

  alias Ravix.Fountain.FakeTransport
  alias Ravix.Repo
  alias Ravix.Terminal
  alias Ravix.Tracks
  alias Ravix.Tracks.Track

  setup do
    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project)
    %{owner: owner, project: project, track: track}
  end

  test "a running machine answers the probe and the wake is done", ctx do
    test = self()

    expect(Terminal, :status, fn user, id ->
      send(test, {:probed, user.id, id})
      {:ok, %Terminal.Status{available: true, why: nil, cwd: ctx.track.workdir}}
    end)

    assert :ok = Tracks.wake(ctx.owner, ctx.track.id)
    assert_received {:probed, owner_id, track_id}
    assert {owner_id, track_id} == {ctx.owner.id, ctx.track.id}
  end

  test "a machine that still does not answer is a refusal to show, not success", ctx do
    expect(Terminal, :status, fn _, _ ->
      {:ok, %Terminal.Status{available: false, why: :unreachable, cwd: ctx.track.workdir}}
    end)

    assert {:error, {:conflict, "machine_not_awake", message}} =
             Tracks.wake(ctx.owner, ctx.track.id)

    assert message =~ "did not wake"
  end

  test "a Read member cannot wake the machine and nothing is asked of it", ctx do
    reader = insert_user()
    insert_track_member(ctx.track, reader, role: :read)
    reject(&Terminal.status/2)

    assert {:error, {:forbidden, _}} = Tracks.wake(reader, ctx.track.id)
  end

  test "somebody with no access to the track is told it does not exist", ctx do
    reject(&Terminal.status/2)
    assert {:error, :not_found} = Tracks.wake(insert_user(), ctx.track.id)
  end

  test "setup parked on a sleeping shared machine is woken the way retry wakes it", ctx do
    Repo.update!(
      Ecto.Changeset.change(ctx.track,
        setup_state: "running",
        setup_error_code: "sandbox_suspended"
      )
    )

    test = self()
    reject(&Terminal.status/2)
    client = FakeTransport.client([], verify: false)
    stub(Ravix.Fountain, :client, fn -> client end)
    stub(Ravix.Projects, :prepare_machine, fn _, ^client -> :ok end)

    expect(Ravix.Tracks.Setup, :advance, fn ^client, id ->
      send(test, {:advanced, id})
      :ok
    end)

    assert :ok = Tracks.wake(ctx.owner, ctx.track.id)
    assert_received {:advanced, id}
    assert id == ctx.track.id
    assert Repo.get!(Track, ctx.track.id).setup_state == "retry"
  end
end
