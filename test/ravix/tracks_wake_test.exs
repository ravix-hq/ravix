defmodule Ravix.TracksWakeTest do
  # `Tracks.wake/2`, the inspector's Wake. Fountain is stubbed at its
  # transport (`POST /api/conversations/:id/wake`); access is the real door.
  use Ravix.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Ravix.Fountain.{Client, FakeTransport}
  alias Ravix.Repo
  alias Ravix.Tracks
  alias Ravix.Tracks.Track

  setup do
    owner = insert_user()
    project = insert_project(user: owner)

    track =
      insert_track(project: project)
      |> Ecto.Changeset.change(
        sandbox_layout: :dedicated,
        sandbox_suspended_at: DateTime.utc_now()
      )
      |> Repo.update!()

    track = Repo.update!(Ecto.Changeset.change(track, conversation_id: "conv-#{track.id}"))
    %{owner: owner, project: project, track: track}
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
        {404, %{error: "not_found"}, "could not complete the request"},
        {404, %{errors: %{detail: "Not Found"}}, "could not complete the request"}
      ] do
    test "Fountain refusing with #{status} #{inspect(body)} says why, as a prompt would, and the machine stays asleep",
         ctx do
      client = fountain_answers(ctx, [{unquote(status), [], unquote(Macro.escape(body))}])

      capture_log(fn ->
        assert {:error, %Ravix.Fountain.Error{status: unquote(status)} = error} =
                 Tracks.wake(ctx.owner, ctx.track.id)

        assert RavixWeb.Error.from(error, what_for: "wake the machine").message =~
                 unquote(words)
      end)

      # Asked once, and nothing else was tried after the refusal.
      FakeTransport.verify!(client)
      assert asleep?(ctx.track.id)
    end
  end

  test "a track with no conversation yet has nothing to wake, and Fountain is not asked", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.track, conversation_id: nil))
    reject(&Ravix.Fountain.wake/2)

    assert {:error, {:conflict, "no_conversation", message}} =
             Tracks.wake(ctx.owner, ctx.track.id)

    assert message =~ "no agent session"
    assert asleep?(ctx.track.id)
  end

  test "a deployment with no Fountain says so and asks nothing", ctx do
    stub(Ravix.Fountain, :client, fn -> Client.new("https://f.example", nil) end)
    reject(&Ravix.Fountain.wake/2)

    assert {:error, {:unconfigured, :fountain}} = Tracks.wake(ctx.owner, ctx.track.id)
  end

  test "a Read member is refused before Fountain is asked", ctx do
    reader = insert_user()
    insert_track_member(ctx.track, reader, role: :read)
    reject(&Ravix.Fountain.wake/2)

    assert {:error, {:forbidden, _}} = Tracks.wake(reader, ctx.track.id)
    assert asleep?(ctx.track.id)
  end

  test "somebody with no access, or whose membership was removed, is told it does not exist",
       ctx do
    member = insert_user()
    membership = insert_track_member(ctx.track, member, role: :write)
    Repo.delete!(membership)
    reject(&Ravix.Fountain.wake/2)

    assert {:error, :not_found} = Tracks.wake(member, ctx.track.id)
    assert {:error, :not_found} = Tracks.wake(insert_user(), ctx.track.id)
  end

  test "setup parked on a sleeping shared machine is woken the way retry wakes it", ctx do
    Repo.update!(
      Ecto.Changeset.change(ctx.track,
        sandbox_layout: :shared,
        sandbox_suspended_at: nil,
        setup_state: "running",
        setup_error_code: "sandbox_suspended"
      )
    )

    test = self()
    reject(&Ravix.Fountain.wake/2)
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
