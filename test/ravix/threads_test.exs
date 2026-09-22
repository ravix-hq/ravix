defmodule Ravix.ThreadsTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Ravix.Accounts.Access
  alias Ravix.Fountain
  alias Ravix.Fountain.{FakeTransport, Launch, Shapes}
  alias Ravix.{Ids, MachineCache, PromptQueue, Tracks}
  alias Ravix.Tracks.{Follower, Store}

  setup do
    user = insert_user()
    project = insert_project(user: user)

    track =
      insert_track(project: project, conversation_id: "default", opened_at: DateTime.utc_now())

    client = FakeTransport.client([], verify: false)
    stub(Fountain, :client, fn -> client end)
    %{user: user, project: project, track: track}
  end

  test "legacy writes create and attach the default, without replacing another thread", ctx do
    assert %{id: id, conversation_id: "default"} = Store.thread(ctx.track.id)
    assert id == ctx.track.id
    other = thread(ctx.track)
    :ok = Store.attach_conversation(ctx.track.id, "replacement")
    assert Store.thread(ctx.track.id).conversation_id == "replacement"
    assert Store.thread(ctx.track.id, other.id) == other
    assert Store.track_by_conversation(other.conversation_id).id == ctx.track.id
    :ok = Store.attach_conversation(ctx.track.id, "other-replacement", other.id)
    assert Store.thread(ctx.track.id, other.id).conversation_id == "other-replacement"
    assert Store.get_track(ctx.track.id).conversation_id == "replacement"
  end

  test "a new blank thread sends the full identity and attaches to the existing sandbox", ctx do
    stub(Fountain, :get_conversation, fn _, id ->
      assert id == ctx.track.conversation_id
      {:ok, Shapes.conversation(%{"id" => id, "sandbox_id" => "existing-sandbox"})}
    end)

    expect(Fountain, :create_conversation, fn _, %Launch{} = launch ->
      assert launch.agent_id == ctx.project.agent_id
      assert launch.environment_id == ctx.project.environment_id
      assert launch.vault_id == ctx.project.vault_id
      assert launch.sandbox_id == "existing-sandbox"
      assert launch.prompt == nil
      assert %{thread_id: id} = Ids.parse_channel(launch.channel_id)
      assert id != ctx.track.id
      {:ok, Shapes.conversation(%{"id" => "second"})}
    end)

    assert {:ok, added} = Tracks.add_thread(ctx.user, ctx.track.id)
    assert Store.thread(ctx.track.id, added.id).conversation_id == "second"
    assert Store.get_track(ctx.track.id).conversation_id == "default"
    assert Store.get_track(ctx.track.id).workdir == ctx.track.workdir
  end

  test "thread IDs never grant another track's access", ctx do
    other = insert_track()
    other_thread = thread(other)
    assert {:error, :not_found} = Access.thread_access(ctx.user, ctx.track.id, other_thread.id)

    assert {:error, :not_found} =
             Tracks.events(ctx.user, ctx.track.id, thread_id: other_thread.id)

    assert {:error, :not_found} = Tracks.interrupt(ctx.user, ctx.track.id, other_thread.id)

    assert {:error, :not_found} =
             Tracks.prompt(ctx.user, ctx.track.id, %{
               thread_id: other_thread.id,
               prompt: "secret",
               request_id: Ecto.UUID.generate()
             })

    assert {:error, :not_found} = Tracks.add_thread(insert_user(), ctx.track.id)
  end

  test "transcripts and interrupt use the selected conversation", ctx do
    other = thread(ctx.track)

    expect(Fountain, :events, fn _, id, [prompts: true] ->
      assert id == other.conversation_id
      {:ok, []}
    end)

    expect(Fountain, :interrupt, fn _, id ->
      assert id == other.conversation_id
      :ok
    end)

    assert {:ok, _} = Tracks.events(ctx.user, ctx.track.id, thread_id: other.id)
    assert :ok = Tracks.interrupt(ctx.user, ctx.track.id, other.id)
  end

  test "queue heads and receipts are per thread, and delivery targets the right conversation",
       ctx do
    other = thread(ctx.track)
    request = Ecto.UUID.generate()

    assert {:ok, first} =
             Tracks.prompt(ctx.user, ctx.track.id, %{prompt: "first", request_id: request})

    assert {:ok, second} =
             Tracks.prompt(ctx.user, ctx.track.id, %{
               thread_id: other.id,
               prompt: "second",
               request_id: Ecto.UUID.generate()
             })

    assert {:error, {:conflict, "request_id_used", _}} =
             Tracks.prompt(ctx.user, ctx.track.id, %{
               thread_id: other.id,
               prompt: "collision",
               request_id: request
             })

    assert Enum.sort(Enum.map(PromptQueue.Store.heads(), & &1.id)) ==
             Enum.sort([first.id, second.id])

    assert {:ok, [%{prompt: "second"}]} = PromptQueue.list(ctx.user, ctx.track.id, other.id)
    PromptQueue.Store.set_status(first.id, :failed, "hold the default")
    stub(Ravix.Projects, :prepare_machine, fn _, _ -> :ok end)
    stub(Ravix.Previews, :prepare_agent_preview, fn _ -> "" end)

    expect(Fountain, :get_conversation, fn _, id ->
      assert id == other.conversation_id
      {:ok, Shapes.conversation(%{"id" => id, "status" => "pending", "turn_count" => 0})}
    end)

    expect(Fountain, :turns, fn _, id ->
      assert id == other.conversation_id
      {:ok, []}
    end)

    expect(Fountain, :prompt, fn _, id, text, [], opts ->
      assert text =~ ctx.track.workdir
      assert String.ends_with?(text, "second")
      assert id == other.conversation_id
      assert opts[:client_request_id] == second.id
      :ok
    end)

    server = start_supervised!({PromptQueue.Server, name: nil, interval: false})
    Sandbox.allow(Repo, self(), server)
    for mod <- [Fountain, Ravix.Projects, Ravix.Previews], do: allow(mod, self(), server)
    assert :ok = PromptQueue.Server.tick(server)
    assert PromptQueue.Store.get(second.id).status == :sent
    assert PromptQueue.Store.get(first.id).status == :failed
  end

  test "two threads have distinct cluster followers and subscriptions", ctx do
    other = thread(ctx.track)
    opts = [stream_opts: [max_retries: 0], linger_ms: 1]
    assert {:ok, first} = Tracks.follow(ctx.user, ctx.track.id, opts)

    assert {:ok, second} =
             Tracks.follow(ctx.user, ctx.track.id, Keyword.put(opts, :thread_id, other.id))

    assert first != second
    assert Follower.whereis(ctx.track.id) == first
    assert Follower.whereis(other.id) == second
    refs = Enum.map([first, second], &Process.monitor/1)
    Follower.unsubscribe(ctx.track.id)
    Follower.unsubscribe(other.id)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, :normal}, 1_000)
  end

  test "a machine without a sandbox refuses a new thread without provisioning", ctx do
    expect(Fountain, :get_conversation, fn _, _ ->
      {:ok, Shapes.conversation(%{"id" => "default"})}
    end)

    assert {:error, {:conflict, "not_open", _}} = Tracks.add_thread(ctx.user, ctx.track.id)
    assert length(Store.threads_of(ctx.track.id)) == 1
  end

  test "revocation during launch unwinds the unattached conversation", ctx do
    member = insert_user()
    insert_track_member(ctx.track, member)

    stub(Fountain, :get_conversation, fn _, _ ->
      {:ok, Shapes.conversation(%{"id" => "default", "sandbox_id" => "sandbox"})}
    end)

    expect(Fountain, :create_conversation, fn _, _ ->
      Repo.delete_all(Ravix.Tracks.TrackMember)
      {:ok, Shapes.conversation(%{"id" => "orphan"})}
    end)

    expect(Fountain, :terminate, fn _, "orphan" -> :ok end)
    assert {:error, :not_found} = Tracks.add_thread(member, ctx.track.id)
    assert length(Store.threads_of(ctx.track.id)) == 1
  end

  test "closing the track closes every thread and refuses later inserts", ctx do
    other = thread(ctx.track)
    assert :ok = Store.close_track(ctx.track.id)
    assert Store.thread(ctx.track.id).closed_at
    assert Store.thread(ctx.track.id, other.id).closed_at

    assert {:error, :not_found} =
             Store.create_thread(%{track_id: ctx.track.id, title: "Too late"})
  end

  test "reading one thread leaves the other unread in the rail", ctx do
    other = thread(ctx.track)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    stub(MachineCache, :conversations, fn _, _, _ ->
      {:ok,
       Enum.map(
         ["default", other.conversation_id],
         &Shapes.conversation(%{"id" => &1, "status" => "idle", "last_active_at" => now})
       )}
    end)

    assert :ok = Tracks.mark_read(ctx.user, ctx.track.id)
    assert {:ok, [view]} = Tracks.list(ctx.user, ctx.project.id)
    assert view.unread
    assert Enum.find(view.threads, &(&1.id == other.id)).unread
    assert :ok = Tracks.mark_read(ctx.user, ctx.track.id, other.id)
    assert {:ok, [%{unread: false}]} = Tracks.list(ctx.user, ctx.project.id)
  end

  defp thread(track) do
    {:ok, thread} =
      Store.create_thread(%{
        track_id: track.id,
        conversation_id: Ecto.UUID.generate(),
        title: "Next"
      })

    thread
  end
end
