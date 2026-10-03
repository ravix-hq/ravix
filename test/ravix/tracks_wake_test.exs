defmodule Ravix.TracksWakeTest do
  # `Tracks.wake/2`, the inspector's Wake. The machine is stubbed at the
  # terminal's probe and the provider boundary; access is the real door.
  use Ravix.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Ravix.Fountain.{Client, FakeTransport}
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

  describe "a track with a conversation" do
    # Fountain is asked, not the terminal: `POST /api/conversations/:id/wake`.
    setup ctx do
      track =
        Repo.update!(
          Ecto.Changeset.change(ctx.track,
            conversation_id: "conv-#{ctx.track.id}",
            sandbox_layout: :dedicated,
            sandbox_suspended_at: DateTime.utc_now()
          )
        )

      Map.put(ctx, :track, track)
    end

    defp fountain_answers(ctx, responses) do
      path = "/api/conversations/conv-#{ctx.track.id}/wake"
      client = FakeTransport.client(Enum.map(responses, &{%{method: "POST", path: path}, &1}))
      stub(Ravix.Fountain, :client, fn -> client end)
      client
    end

    defp asleep?(track_id), do: Tracks.asleep?(Repo.get!(Track, track_id))

    for status <- ["awake", "waking"] do
      test "Fountain answering #{status} is a woken machine, and the asleep mark is cleared",
           ctx do
        client = fountain_answers(ctx, [{200, [], %{status: unquote(status)}}])
        reject(&Terminal.status/2)
        assert asleep?(ctx.track.id)

        assert :ok = Tracks.wake(ctx.owner, ctx.track.id)
        FakeTransport.verify!(client)
        refute asleep?(ctx.track.id)
      end
    end

    for {status, body, words} <- [
          {402, %{error: "insufficient_credits"}, "out of credits"},
          {409, %{error: "sandbox_reset_pending", message: "torn down"}, "torn down or reset"},
          {410, %{error: "conversation_terminated"}, "has ended"},
          {503, %{error: "sandbox_unavailable"}, "not available right now"},
          {404, %{error: "not_found"}, "could not complete the request"}
        ] do
      test "Fountain refusing with #{status} says why, as a prompt would, and the machine stays asleep",
           ctx do
        fountain_answers(ctx, [{unquote(status), [], unquote(Macro.escape(body))}])
        reject(&Terminal.status/2)

        capture_log(fn ->
          assert {:error, %Ravix.Fountain.Error{status: unquote(status)} = error} =
                   Tracks.wake(ctx.owner, ctx.track.id)

          assert RavixWeb.Error.from(error, what_for: "wake the machine").message =~
                   unquote(words)
        end)

        assert asleep?(ctx.track.id)
      end
    end

    test "a Fountain that does not serve the route falls back to the probe", ctx do
      client = fountain_answers(ctx, [{404, [], %{errors: %{detail: "Not Found"}}}])

      expect(Terminal, :status, fn _, _ ->
        {:ok, %Terminal.Status{available: true, why: nil, cwd: ctx.track.workdir}}
      end)

      capture_log(fn -> assert :ok = Tracks.wake(ctx.owner, ctx.track.id) end)
      FakeTransport.verify!(client)
    end

    test "a deployment with no Fountain says so and asks nothing", ctx do
      stub(Ravix.Fountain, :client, fn -> Client.new("https://f.example", nil) end)
      reject(&Ravix.Fountain.wake/2)
      reject(&Terminal.status/2)

      assert {:error, {:unconfigured, :fountain}} = Tracks.wake(ctx.owner, ctx.track.id)
    end

    test "a Read member is refused before Fountain is asked", ctx do
      reader = insert_user()
      insert_track_member(ctx.track, reader, role: :read)
      reject(&Ravix.Fountain.wake/2)

      assert {:error, {:forbidden, _}} = Tracks.wake(reader, ctx.track.id)
      assert asleep?(ctx.track.id)
    end

    test "a removed member is told it does not exist before Fountain is asked", ctx do
      member = insert_user()
      membership = insert_track_member(ctx.track, member, role: :write)
      Repo.delete!(membership)
      reject(&Ravix.Fountain.wake/2)

      assert {:error, :not_found} = Tracks.wake(member, ctx.track.id)
    end
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
