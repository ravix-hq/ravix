defmodule Ravix.StartThreadTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts.Inference
  alias Ravix.Fountain
  alias Ravix.Fountain.{FakeTransport, Shapes}
  alias Ravix.PromptQueue
  alias Ravix.PromptQueue.Body
  alias Ravix.Tracks
  alias Ravix.Tracks.{Store, Thread}

  @models %{"claude" => ["anthropic/claude-opus-5", "anthropic/claude-sonnet-5"]}
  @pixel "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j4WQAAAAASUVORK5CYII="

  setup do
    owner = insert_user(credential_set_id: "owner-set")
    project = insert_project(user: owner, runtime: "claude", credential_set_id: "owner-set")

    track =
      insert_track(project: project, conversation_id: "first", opened_at: DateTime.utc_now())

    client =
      FakeTransport.client(
        [{%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}}],
        verify: false
      )

    stub(Fountain, :client, fn -> client end)

    stub(Ravix.MachineCache, :catalog, fn _ ->
      {:ok, %Shapes.Catalog{runtimes: ["claude"], models: @models}}
    end)

    stub(Fountain, :get_conversation, fn _, _ ->
      {:ok, Shapes.conversation(%{"id" => "first", "sandbox_id" => "disk"})}
    end)

    stub(Fountain, :sandbox, fn _, "disk" ->
      {:ok, Shapes.sandbox(%{"id" => "disk", "agent_id" => project.agent_id})}
    end)

    stub(Inference, :usable?, fn _, _, _ -> {:ok, true} end)
    stub(Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)
    stub(Inference, :usable_agents, fn _, _ -> {:ok, [:claude]} end)
    stub(Ravix.MachineCache, :machine_of, fn _, _ -> {:ok, nil} end)

    %{owner: owner, project: project, track: track}
  end

  defp payload(prompt, extra \\ %{}),
    do: Map.merge(%{prompt: prompt, request_id: Ecto.UUID.generate()}, extra)

  defp created(id \\ Ecto.UUID.generate()) do
    fn _, launch ->
      send(self(), {:launched, launch})
      {:ok, Shapes.conversation(%{"id" => id, "sandbox_id" => launch.sandbox_id})}
    end
  end

  describe "Thread.title_from/1" do
    test "keeps a short prompt, collapsing its lines and spaces into one" do
      assert Thread.title_from("Fix the build") == "Fix the build"
      assert Thread.title_from("  Fix\n\nthe\tbuild  \n") == "Fix the build"
    end

    test "cuts a long prompt at a word boundary near forty characters" do
      title =
        Thread.title_from(
          "Refactor the prompt queue so retries share one code path\nand add tests"
        )

      assert title == "Refactor the prompt queue so retries…"
      assert String.length(title) <= 41
      refute title =~ "\n"
    end

    test "cuts a single unbroken word at forty characters" do
      word = String.duplicate("a", 60)
      assert Thread.title_from(word) == String.duplicate("a", 40) <> "…"
    end

    test "falls back to New thread for a prompt with no words" do
      assert Thread.title_from("") == "New thread"
      assert Thread.title_from(" \n ") == "New thread"
      assert Thread.title_from(nil) == "New thread"
    end
  end

  test "creates the thread titled by its prompt and queues that prompt on it", ctx do
    expect(Fountain, :create_conversation, created("started"))

    request =
      payload("Explain the\nprompt queue", %{images: [%{data: @pixel, media_type: "image/png"}]})

    assert {:ok, thread} =
             Tracks.start_thread(ctx.owner, ctx.track.id, %{runtime: "claude"}, request)

    assert_received {:launched, launch}
    assert launch.prompt == nil
    assert thread.title == "Explain Prompt Queue"
    assert thread.conversation_id == "started"
    assert thread.runtime == "claude"

    assert [%{id: id, thread_id: thread_id, user_id: user_id}] =
             PromptQueue.Store.queued_prompts(ctx.track.id)

    assert {id, thread_id, user_id} == {request.request_id, thread.id, ctx.owner.id}

    assert %Body{prompt: "Explain the\nprompt queue", images: [%{media_type: "image/png"}]} =
             Body.decode(PromptQueue.Store.get(id).body)
  end

  test "an image-only first prompt is titled New thread", ctx do
    expect(Fountain, :create_conversation, created())

    assert {:ok, thread} =
             Tracks.start_thread(
               ctx.owner,
               ctx.track.id,
               %{},
               payload("", %{images: [%{data: @pixel, media_type: "image/png"}]})
             )

    assert thread.title == "New thread"
    assert [_] = PromptQueue.Store.queued_prompts(ctx.track.id)
  end

  test "an empty prompt or missing request id is refused before any conversation", ctx do
    reject(&Fountain.create_conversation/2)

    assert {:error, {:unprocessable, "empty_prompt", _}} =
             Tracks.start_thread(ctx.owner, ctx.track.id, %{}, payload("   "))

    assert {:error, {:unprocessable, "request_id_required", _}} =
             Tracks.start_thread(ctx.owner, ctx.track.id, %{}, %{prompt: "hi"})

    assert [_] = Store.threads_of(ctx.track.id)
  end

  test "the same draft sent twice starts one thread", ctx do
    expect(Fountain, :create_conversation, 1, created())
    request = payload("Only once")

    assert {:ok, first} = Tracks.start_thread(ctx.owner, ctx.track.id, %{}, request)
    assert {:ok, again} = Tracks.start_thread(ctx.owner, ctx.track.id, %{}, request)
    assert again.id == first.id
    assert length(Store.threads_of(ctx.track.id)) == 2
    assert [_] = PromptQueue.Store.queued_prompts(ctx.track.id)
  end

  test "a send that loses the race to its twin answers with the twin's thread", ctx do
    request = payload("Raced")
    expect(Fountain, :create_conversation, created())
    assert {:ok, winner} = Tracks.start_thread(ctx.owner, ctx.track.id, %{}, request)

    # The twin checked for a receipt before the winner saved one, so it goes
    # on to create a conversation of its own; the save is what catches it.
    stub(PromptQueue.Store, :get, fn id ->
      if Process.put(:raced, true),
        do: call_original(PromptQueue.Store, :get, [id]),
        else: nil
    end)

    expect(Fountain, :create_conversation, created("loser"))
    expect(Fountain, :terminate, fn _, "loser" -> :ok end)

    assert {:ok, answer} = Tracks.start_thread(ctx.owner, ctx.track.id, %{}, request)
    assert answer.id == winner.id
    assert length(Store.threads_of(ctx.track.id)) == 2
    assert [%{thread_id: thread_id}] = PromptQueue.Store.queued_prompts(ctx.track.id)
    assert thread_id == winner.id
  end

  test "a prompt that cannot be queued leaves no thread and ends its conversation", ctx do
    other = insert_user()
    insert_project_member(ctx.project, other)
    request = payload("Collides")

    {:ok, _} =
      PromptQueue.Store.enqueue(
        ctx.track.id,
        other.id,
        other.login,
        request.request_id,
        %Body{prompt: "someone else's", images: []},
        ctx.track.id
      )

    reject(&Fountain.create_conversation/2)

    assert {:error, {:conflict, "request_id_used", _}} =
             Tracks.start_thread(ctx.owner, ctx.track.id, %{}, request)

    assert [_] = Store.threads_of(ctx.track.id)
  end

  test "a refused save rolls the thread back with its prompt and ends the conversation", ctx do
    stub(PromptQueue.Store, :enqueue, fn _, _, _, _, _, _ ->
      {:error, {:conflict, "queue_full", "Full."}}
    end)

    expect(Fountain, :create_conversation, created("orphan"))
    expect(Fountain, :terminate, fn _, "orphan" -> :ok end)

    assert {:error, {:conflict, "queue_full", _}} =
             Tracks.start_thread(ctx.owner, ctx.track.id, %{}, payload("Fresh"))

    assert [_] = Store.threads_of(ctx.track.id)
  end

  test "outsiders, removed members and closed tracks cannot start a thread", ctx do
    reject(&Fountain.create_conversation/2)
    outsider = insert_user()

    assert {:error, :not_found} =
             Tracks.start_thread(outsider, ctx.track.id, %{}, payload("let me in"))

    member = insert_user()
    insert_project_member(ctx.project, member)
    Ravix.Repo.delete_all(Ravix.Projects.ProjectMember)

    assert {:error, :not_found} =
             Tracks.start_thread(member, ctx.track.id, %{}, payload("still here?"))

    Ravix.Repo.update!(Ecto.Changeset.change(ctx.track, closed_at: DateTime.utc_now()))

    assert {:error, _} = Tracks.start_thread(ctx.owner, ctx.track.id, %{}, payload("closed"))
    assert [_] = Store.threads_of(ctx.track.id)
    assert [] = PromptQueue.Store.queued_prompts(ctx.track.id)
  end

  test "access lost while the conversation is created leaves nothing behind", ctx do
    member = insert_user()
    insert_project_member(ctx.project, member)

    expect(Fountain, :create_conversation, fn _, launch ->
      Ravix.Repo.delete_all(Ravix.Projects.ProjectMember)
      {:ok, Shapes.conversation(%{"id" => "late", "sandbox_id" => launch.sandbox_id})}
    end)

    expect(Fountain, :terminate, fn _, "late" -> :ok end)

    assert {:error, :not_found} =
             Tracks.start_thread(member, ctx.track.id, %{}, payload("race the removal"))

    assert [_] = Store.threads_of(ctx.track.id)
    assert [] = PromptQueue.Store.queued_prompts(ctx.track.id)
  end
end
