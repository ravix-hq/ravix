defmodule Ravix.TracksWakeTest do
  # `Tracks.wake/2`, the inspector's Wake. Fountain is stubbed at its
  # transport (`POST /api/conversations/:id/wake`); access is the real door.
  use Ravix.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Ravix.Fountain.{Client, FakeTransport, Shapes}
  alias Ravix.Repo
  alias Ravix.Tracks
  alias Ravix.Tracks.CredentialRecovery
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

  describe "a conversation whose credential set has since changed" do
    # Fountain refuses it for good, so waking it again is refused again: the
    # wake starts its successor on the same disk instead, as a prompt does.
    setup ctx do
      client =
        fountain_answers(ctx, [
          {409, [], %{error: "inference_source_changed", message: "source changed"}}
        ])

      %{client: client}
    end

    test "is carried onto a successor, which is the wake, and the mark is cleared", ctx do
      track_id = ctx.track.id
      stub(CredentialRecovery, :enabled?, fn _, _ -> true end)

      expect(CredentialRecovery, :reject, fn %{id: ^track_id}, _, ^track_id ->
        {:ok, :ok}
      end)

      expect(CredentialRecovery, :prepare, fn _, %{id: ^track_id}, _, ^track_id ->
        :rebound
      end)

      assert :ok = Tracks.wake(ctx.owner, track_id)
      FakeTransport.verify!(ctx.client)
      refute asleep?(track_id)
    end

    test "a successor not ready yet says so, and the mark stays", ctx do
      stub(CredentialRecovery, :enabled?, fn _, _ -> true end)
      stub(CredentialRecovery, :reject, fn _, _, _ -> {:ok, :ok} end)
      stub(CredentialRecovery, :prepare, fn _, _, _, _ -> :waiting end)

      assert {:error, {:conflict, "agent_reconnecting", message}} =
               Tracks.wake(ctx.owner, ctx.track.id)

      assert message =~ "Send a message"
      assert asleep?(ctx.track.id)
    end

    test "a track recovery does not cover keeps the refusal, and nothing is recovered", ctx do
      stub(CredentialRecovery, :enabled?, fn _, _ -> false end)
      reject(&CredentialRecovery.reject/3)
      reject(&CredentialRecovery.prepare/4)

      capture_log(fn ->
        assert {:error, %Ravix.Fountain.Error{code: "inference_source_changed"}} =
                 Tracks.wake(ctx.owner, ctx.track.id)
      end)

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

  describe "a machine still resuming after Fountain answers" do
    # Fountain answers `waking` with the machine still coming up: reads are
    # refused as suspended, or fail as unreachable, for tens of seconds
    # (managoat/fountain#2555). The wake answers once a live read does.
    setup ctx do
      track = Repo.update!(Ecto.Changeset.change(ctx.track, sandbox_id: "sbx-#{ctx.track.id}"))
      %{track: track}
    end

    defp listing(ctx), do: %{method: "GET", path: "/api/sandboxes/sbx-#{ctx.track.id}/files"}

    defp wake_call(ctx),
      do: %{method: "POST", path: "/api/conversations/conv-#{ctx.track.id}/wake"}

    defp scripted(ctx, wake, reads, opts \\ []) do
      client =
        FakeTransport.client(
          [{wake_call(ctx), wake} | Enum.map(reads, &{listing(ctx), &1})],
          opts
        )

      stub(Ravix.Fountain, :client, fn -> client end)
      client
    end

    @suspended {409, [], %{error: "sandbox_not_ready", status: "suspended"}}
    @unreachable {503, [],
                  %{error: "sandbox_unreachable", message: "could not reach the sandbox"}}
    @live {200, [], %{data: %{path: "/home/sprite", entries: [], truncated: false}}}

    test "waits through refused and unreachable reads, then clears the mark", ctx do
      client = scripted(ctx, {200, [], %{status: "waking"}}, [@suspended, @unreachable, @live])

      capture_log(fn -> assert :ok = Tracks.wake(ctx.owner, ctx.track.id) end)
      FakeTransport.verify!(client)
      refute asleep?(ctx.track.id)
    end

    test "a listing from the park's snapshot is the machine still parked", ctx do
      snapshot =
        {200, [],
         %{data: %{path: "/home/sprite", entries: [], snapshot_at: "2026-10-03T03:00:00Z"}}}

      client = scripted(ctx, {200, [], %{status: "waking"}}, [snapshot, @live])

      assert :ok = Tracks.wake(ctx.owner, ctx.track.id)
      FakeTransport.verify!(client)
      refute asleep?(ctx.track.id)
    end

    test "one that never answers is refused as still waking, and stays marked asleep", ctx do
      # More refusals than the test config's wait can ask for.
      scripted(ctx, {200, [], %{status: "waking"}}, List.duplicate(@suspended, 40), verify: false)

      assert {:error, {:unavailable, "machine_waking", message} = reason} =
               Tracks.wake(ctx.owner, ctx.track.id)

      assert message =~ "still waking"
      assert RavixWeb.Error.from(reason).message =~ "still waking"
      assert asleep?(ctx.track.id)
    end

    test "a sandbox the read cannot find leaves the wake Fountain accepted standing", ctx do
      client =
        scripted(ctx, {200, [], %{status: "waking"}}, [
          {404, [], %{error: "sandbox_not_found"}}
        ])

      capture_log(fn -> assert :ok = Tracks.wake(ctx.owner, ctx.track.id) end)
      FakeTransport.verify!(client)
      refute asleep?(ctx.track.id)
    end

    test "an awake machine not marked asleep is not read at all", ctx do
      Repo.update!(Ecto.Changeset.change(ctx.track, sandbox_suspended_at: nil))
      client = scripted(ctx, {200, [], %{status: "awake"}}, [])

      assert :ok = Tracks.wake(ctx.owner, ctx.track.id)
      FakeTransport.verify!(client)
    end

    test "an awake answer for a row marked asleep is read before the mark clears", ctx do
      client = scripted(ctx, {200, [], %{status: "awake"}}, [@suspended, @live])

      assert :ok = Tracks.wake(ctx.owner, ctx.track.id)
      FakeTransport.verify!(client)
      refute asleep?(ctx.track.id)
    end
  end

  describe "wake_on_open/3" do
    # Somebody opened the track (RAV-141). Fountain is stubbed at its own
    # functions, and the conversation list at the memo, which is shared
    # between tests that run at once.
    setup ctx do
      track =
        Repo.update!(
          Ecto.Changeset.change(ctx.track,
            conversation_id: "conv-#{ctx.track.id}",
            sandbox_layout: :dedicated,
            sandbox_suspended_at: DateTime.utc_now()
          )
        )

      stub(Ravix.Fountain, :client, fn -> FakeTransport.client([], verify: false) end)
      listed(%{})
      Map.put(ctx, :track, track)
    end

    defp listed(statuses) do
      stub(Ravix.MachineCache, :conversations, fn _, _, _ ->
        {:ok,
         for({id, status} <- statuses, do: Shapes.conversation(%{"id" => id, "status" => status}))}
      end)
    end

    defp wakes(answer) do
      test = self()

      expect(Ravix.Fountain, :wake, fn _, id ->
        send(test, {:woke, id})
        answer
      end)
    end

    defp sleeping?(track_id), do: Tracks.asleep?(Repo.get!(Track, track_id))

    for state <- [:awake, :waking] do
      test "#{state} is answered as it is and clears the asleep mark", ctx do
        wakes({:ok, unquote(state)})

        assert {:ok, unquote(state)} = Tracks.wake_on_open(ctx.owner, ctx.track.id, nil)
        assert_received {:woke, conversation}
        assert conversation == ctx.track.conversation_id
        refute sleeping?(ctx.track.id)
      end
    end

    test "only the thread opened is woken, not its siblings", ctx do
      {:ok, review} =
        Tracks.Store.create_thread(%{
          track_id: ctx.track.id,
          title: "Review",
          conversation_id: "conv-review"
        })

      wakes({:ok, :waking})

      assert {:ok, :waking} = Tracks.wake_on_open(ctx.owner, ctx.track.id, review.id)
      assert_received {:woke, "conv-review"}
      refute_received {:woke, _}
    end

    test "a thread whose credential set has changed is recovered, that thread and no other",
         ctx do
      {:ok, review} =
        Tracks.Store.create_thread(%{
          track_id: ctx.track.id,
          title: "Review",
          conversation_id: "conv-review"
        })

      review_id = review.id
      wakes({:error, %Ravix.Fountain.Error{status: 409, code: "inference_source_changed"}})
      stub(CredentialRecovery, :enabled?, fn _, _ -> true end)
      expect(CredentialRecovery, :reject, fn _, _, ^review_id -> {:ok, :ok} end)
      expect(CredentialRecovery, :prepare, fn _, _, _, ^review_id -> :rebound end)

      assert {:ok, :waking} = Tracks.wake_on_open(ctx.owner, ctx.track.id, review_id)
      refute sleeping?(ctx.track.id)
    end

    test "a refusal is returned for the caller to keep, and the mark stays", ctx do
      refusal = %Ravix.Fountain.Error{status: 402, code: "insufficient_credits"}
      wakes({:error, refusal})

      assert {:error, ^refusal} = Tracks.wake_on_open(ctx.owner, ctx.track.id, nil)
      assert sleeping?(ctx.track.id)
    end

    test "a Read member, a stranger and a removed member never reach Fountain", ctx do
      reject(&Ravix.Fountain.wake/2)
      reject(&Ravix.MachineCache.conversations/3)
      reader = insert_user()
      insert_track_member(ctx.track, reader, role: :read)
      removed = insert_user()
      Repo.delete!(insert_track_member(ctx.track, removed, role: :write))

      assert {:error, {:forbidden, _}} = Tracks.wake_on_open(reader, ctx.track.id, nil)
      assert {:error, :not_found} = Tracks.wake_on_open(insert_user(), ctx.track.id, nil)
      assert {:error, :not_found} = Tracks.wake_on_open(removed, ctx.track.id, nil)
      assert sleeping?(ctx.track.id)
    end

    for {name, attrs} <- [
          {"no conversation", [conversation_id: nil]},
          {"setup still running", [setup_state: "running"]},
          {"setup parked on a sleeping machine",
           [setup_state: "running", setup_error_code: "sandbox_suspended"]},
          {"setup that failed", [setup_state: "failed"]},
          {"a closed track", [closed_at: DateTime.utc_now()]},
          {"a closing machine", [sandbox_state: :closing]}
        ] do
      test "#{name} is skipped without asking Fountain", ctx do
        Repo.update!(Ecto.Changeset.change(ctx.track, unquote(Macro.escape(attrs))))
        reject(&Ravix.Fountain.wake/2)
        reject(&Tracks.Setup.advance/2)

        assert {:ok, :skipped} = Tracks.wake_on_open(ctx.owner, ctx.track.id, nil)
      end
    end

    test "a closed thread is skipped", ctx do
      {:ok, review} =
        Tracks.Store.create_thread(%{track_id: ctx.track.id, title: "Old", conversation_id: "c"})

      Repo.update!(Ecto.Changeset.change(review, closed_at: DateTime.utc_now()))
      reject(&Ravix.Fountain.wake/2)

      assert {:ok, :skipped} = Tracks.wake_on_open(ctx.owner, ctx.track.id, review.id)
    end

    for status <- ["running", "pending", "terminated", "failed"] do
      test "a conversation the list says is #{status} is skipped", ctx do
        listed(%{ctx.track.conversation_id => unquote(status)})
        reject(&Ravix.Fountain.wake/2)

        assert {:ok, :skipped} = Tracks.wake_on_open(ctx.owner, ctx.track.id, nil)
      end
    end

    test "a conversation the list says is idle is asked", ctx do
      listed(%{ctx.track.conversation_id => "idle"})
      wakes({:ok, :awake})
      assert {:ok, :awake} = Tracks.wake_on_open(ctx.owner, ctx.track.id, nil)
    end
  end
end
