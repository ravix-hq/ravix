defmodule Ravix.ThreadContextTest do
  @moduledoc "RAV-50: a new thread's first prompt carries its siblings' transcripts."
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Fountain
  alias Ravix.Fountain.{FakeTransport, Shapes}
  alias Ravix.{MachineCache, People, PromptQueue, Tracks}
  alias Ravix.PromptQueue.Body
  alias Ravix.Tracks.{Carry, Store}

  setup do
    owner = insert_user()
    member = insert_user()
    creator = insert_user()
    project = insert_project(user: owner, runtime: "claude")
    insert_project_member(project, member)
    insert_project_member(project, creator)

    track =
      insert_track(project: project, conversation_id: "default", opened_at: DateTime.utc_now())

    sibling = thread(track, "sibling-conversation", "Fix the login")

    private =
      insert_track(
        project: project,
        visibility: :private,
        created_by: creator.id,
        created_by_login: creator.login,
        conversation_id: "private-default"
      )

    secret = thread(private, "secret-conversation", "Private work")

    client = FakeTransport.client([], verify: false)
    stub(Fountain, :client, fn -> client end)

    stub(Ravix.Accounts.Inference, :usable?, fn _owner, "claude", [fresh: true] -> {:ok, true} end)

    stub(MachineCache, :catalog, fn _ ->
      {:ok, %Shapes.Catalog{runtimes: ["claude"], models: %{"claude" => [project.model]}}}
    end)

    stub(Fountain, :get_conversation, fn _, id ->
      {:ok, Shapes.conversation(%{"id" => id, "sandbox_id" => "existing-sandbox"})}
    end)

    stub(Fountain, :turns, fn _, _ -> {:ok, []} end)

    stub(Fountain, :events_page, fn _, id, opts ->
      Ravix.TranscriptFixture.events_page(log(id), opts)
    end)

    %{
      owner: owner,
      member: member,
      creator: creator,
      project: project,
      track: track,
      sibling: sibling,
      private: private,
      secret: secret
    }
  end

  test "the first prompt carries the chosen threads' digest in front of the person's words",
       ctx do
    expect(Fountain, :create_conversation, fn _, _launch ->
      {:ok, Shapes.conversation(%{"id" => "new-conversation"})}
    end)

    request = Ecto.UUID.generate()

    assert {:ok, thread} =
             start(ctx.owner, ctx.track.id, request, [ctx.sibling.id, ctx.track.id])

    # Named for what was asked, not for what was carried in.
    assert thread.title == "Carry on"

    body = request |> PromptQueue.Store.get() |> Map.fetch!(:body) |> Body.decode()
    assert {["Fix the login", _default], "Carry on"} = Carry.split(body.prompt)
    assert body.prompt =~ "User: Why does login fail?"
    assert body.prompt =~ "Agent: The cookie expired."
    assert body.prompt =~ "Changed files: lib/auth.ex"
    refute body.prompt =~ "tool noise"
  end

  test "without sources the prompt is sent as written", ctx do
    expect(Fountain, :create_conversation, fn _, _ ->
      {:ok, Shapes.conversation(%{"id" => "plain"})}
    end)

    request = Ecto.UUID.generate()
    assert {:ok, _} = start(ctx.owner, ctx.track.id, request, [])
    assert PromptQueue.Store.get(request).body["prompt"] == "Carry on"
  end

  test "sources are offered only from a track this person can read", ctx do
    assert {:ok, offered} = Tracks.context_sources(ctx.member, ctx.track.id)
    assert Enum.map(offered, & &1.id) == [ctx.track.id, ctx.sibling.id]
    refute Enum.any?(offered, &(&1.id == ctx.secret.id))

    assert {:error, :not_found} = Tracks.context_sources(ctx.member, ctx.private.id)
    assert {:error, :not_found} = Tracks.context_sources(ctx.owner, ctx.private.id)
    assert {:ok, [_ | _]} = Tracks.context_sources(ctx.creator, ctx.private.id)
  end

  test "a thread nobody offered is never read: another person's private ids refuse the send",
       ctx do
    reject(&Fountain.create_conversation/2)

    for user <- [ctx.owner, ctx.member],
        forged <- [ctx.secret.id, ctx.private.id, "not-a-thread"] do
      request = Ecto.UUID.generate()

      assert {:error, {:unprocessable, "context_unavailable", _}} =
               start(user, ctx.track.id, request, [ctx.sibling.id, forged])

      refute PromptQueue.Store.get(request)
    end

    assert length(Store.threads_of(ctx.track.id)) == 2
  end

  test "a thread with no conversation yet cannot be carried", ctx do
    {:ok, empty} = Store.create_thread(%{track_id: ctx.track.id, title: "Empty"})
    reject(&Fountain.create_conversation/2)

    assert {:error, {:unprocessable, "context_unavailable", _}} =
             start(ctx.owner, ctx.track.id, Ecto.UUID.generate(), [empty.id])

    assert {:ok, offered} = Tracks.context_sources(ctx.owner, ctx.track.id)
    refute Enum.any?(offered, &(&1.id == empty.id))
  end

  test "someone removed from the project can neither list nor carry", ctx do
    assert {:ok, _} = People.remove_project(ctx.owner, ctx.project.id, ctx.member.login)
    reject(&Fountain.create_conversation/2)

    assert {:error, :not_found} = Tracks.context_sources(ctx.member, ctx.track.id)

    assert {:error, :not_found} =
             start(ctx.member, ctx.track.id, Ecto.UUID.generate(), [ctx.sibling.id])
  end

  test "malformed or too many sources are refused before anything is read", ctx do
    reject(&Fountain.create_conversation/2)
    reject(&Fountain.events_page/3)

    for sources <- ["one", [1], for(n <- 1..9, do: "t#{n}")] do
      assert {:error, {:unprocessable, "context_invalid", _}} =
               start(ctx.owner, ctx.track.id, Ecto.UUID.generate(), sources)
    end
  end

  test "a failed read of a source refuses the send", ctx do
    reject(&Fountain.create_conversation/2)

    stub(Fountain, :events_page, fn _, _, _ ->
      {:error, %Fountain.Error{status: 503, code: "unavailable", message: "down"}}
    end)

    assert {:error, %Fountain.Error{status: 503}} =
             start(ctx.owner, ctx.track.id, Ecto.UUID.generate(), [ctx.sibling.id])
  end

  defp start(user, track_id, request, sources) do
    Tracks.start_thread(user, track_id, %{}, %{
      prompt: "Carry on",
      request_id: request,
      context_thread_ids: sources
    })
  end

  defp thread(track, conversation_id, title) do
    {:ok, thread} =
      Store.create_thread(%{track_id: track.id, conversation_id: conversation_id, title: title})

    thread
  end

  defp log("sibling-conversation") do
    import Ravix.TranscriptFixture, only: [output: 3, text: 1]

    [
      %{
        "id" => 1,
        "turn_id" => "a",
        "kind" => "stage",
        "stage" => "turn",
        "state" => "started",
        "blocks" => [%{"kind" => "prompt", "body" => "Why does login fail?"}]
      },
      output(
        2,
        %{
          sessionUpdate: "tool_call",
          toolCallId: "e",
          kind: "edit",
          locations: [%{path: "lib/auth.ex"}]
        },
        "a"
      ),
      output(
        3,
        %{
          sessionUpdate: "tool_call_update",
          toolCallId: "e",
          status: "completed",
          content: [%{type: "content", content: %{type: "text", text: "tool noise"}}]
        },
        "a"
      ),
      output(4, text("The cookie expired."), "a"),
      %{"id" => 5, "turn_id" => "a", "kind" => "stage", "stage" => "turn", "state" => "completed"}
    ]
  end

  defp log(_conversation), do: []
end
