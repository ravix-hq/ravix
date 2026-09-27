defmodule Ravix.PromptQueue.ShutdownTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Ravix.{Fountain, PromptQueue}
  alias Ravix.PromptQueue.{Server, Store}

  setup do
    user = insert_user()
    project = insert_project(user: user, repo_full_name: nil, vault_id: nil, installation_id: nil)
    stub(Fountain, :client, fn -> Fountain.Client.new("https://fountain.test", "test") end)
    stub(Ravix.Projects, :prepare_machine, fn _, _ -> :ok end)

    stub(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [], next_cursor: nil, has_more: false}}
    end)

    %{user: user, project: project}
  end

  test "shutdown releases preparers, drains POSTs and refuses later claims; another server resumes",
       c do
    preparing = enqueue(c, "preparing")
    posting = enqueue(c, "posting")
    waiting = enqueue(c, "waiting")
    parent = self()

    stub(Fountain, :get_conversation, fn _, id ->
      if id == "waiting" do
        send(parent, {:waiting, self()})
        receive do: (:continue -> :ok)
      end

      {:ok, Fountain.Shapes.conversation(%{"id" => id, "status" => "idle"})}
    end)

    stub(Ravix.Previews, :prepare_agent_preview, fn row ->
      if row.id == preparing.id do
        send(parent, {:preparing, self()})
        receive do: (:continue -> :ok)
      end

      ""
    end)

    stub(Fountain, :prompt, fn _, id, _, _, _ ->
      assert id == "posting"
      send(parent, {:posting, self()})
      receive do: (:continue -> :ok)
    end)

    server = server()
    tick = Task.async(fn -> Server.tick(server) end)
    assert_receive {:preparing, preparer}, 2000
    assert_receive {:posting, poster}, 2000
    assert_receive {:waiting, waiter}, 2000
    assert Store.get(preparing.id).status == :sending
    assert Store.get(posting.id).post_started_at
    monitor = Process.monitor(preparer)
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()

    {child_id, _, _, _} =
      Enum.find(Supervisor.which_children(supervisor), &(elem(&1, 1) == server))

    stop = Task.async(fn -> Supervisor.terminate_child(supervisor, child_id) end)
    assert_receive {:DOWN, ^monitor, :process, ^preparer, :killed}, 2000
    send(waiter, :continue)
    send(poster, :continue)
    assert :ok = Task.await(stop, 6000)
    assert :ok = Task.await(tick)
    assert Store.get(preparing.id).status == :queued
    assert Store.get(preparing.id).claimed_by == nil
    assert Store.get(waiting.id).status == :queued
    assert Store.get(waiting.id).claimed_at == nil
    assert Store.get(posting.id).status == :sent

    stub(Fountain, :get_conversation, fn _, id ->
      {:ok, Fountain.Shapes.conversation(%{"id" => id, "status" => "idle"})}
    end)

    stub(Ravix.Previews, :prepare_agent_preview, fn _ -> "" end)
    expect(Fountain, :prompt, 2, fn _, _, _, _, _ -> :ok end)
    Server.tick(server())
    assert Store.get(preparing.id).status == :sent
    assert Store.get(waiting.id).status == :sent
  end

  test "a POST exceeding the shutdown budget remains ambiguous for recovery", c do
    row = enqueue(c, "unanswered")
    parent = self()

    stub(Fountain, :get_conversation, fn _, id ->
      {:ok, Fountain.Shapes.conversation(%{"id" => id, "status" => "idle"})}
    end)

    stub(Ravix.Previews, :prepare_agent_preview, fn _ -> "" end)

    stub(Fountain, :prompt, fn _, _, _, _, _ ->
      send(parent, {:posting, self()})
      receive do: (:continue -> :ok)
    end)

    server = server()
    tick = Task.async(fn -> Server.tick(server) end)
    assert_receive {:posting, poster}, 2000
    ref = Process.monitor(poster)
    assert :ok = Server.stop(server)
    assert :ok = Task.await(tick)
    assert_receive {:DOWN, ^ref, :process, ^poster, _}, 1000
    assert Store.get(row.id).status == :sending
    assert Store.get(row.id).post_started_at
    Store.recover()
    assert Store.get(row.id).status == :sending
  end

  test "a live owner and legacy claims wait for timeout; departed claims are fenced", c do
    row = enqueue(c, "fenced")
    token = Ecto.UUID.generate()
    assert Store.claim(row.id, token)
    assert Store.get(row.id).claimed_by == Atom.to_string(node())
    Store.recover()
    assert Store.get(row.id).status == :sending

    Store.get(row.id)
    |> Ecto.Changeset.change(claimed_by: nil)
    |> Repo.update!()

    Store.recover()
    assert Store.get(row.id).status == :sending
    Store.get(row.id) |> Ecto.Changeset.change(claimed_by: "departed@host") |> Repo.update!()
    Store.recover()
    assert Store.get(row.id).status == :unconfirmed
    refute Store.begin_post(row.id, token)
    Store.annotate(row.id, :unconfirmed, "Fountain has no turn carrying this prompt's id.")
    assert Store.get(row.id).status == :unconfirmed
    # Absence alone never replays. The stopped preparer's token and lack of
    # POST permission make an explicit release safe even after the lookup.
    Store.release_claim(row.id, token)
    assert Store.get(row.id).status == :queued
  end

  test "a preparer recovered during discovery lag releases its refused POST and delivers once",
       c do
    row = enqueue(c, "discovery-lag")
    parent = self()

    stub(Fountain, :get_conversation, fn _, id ->
      {:ok, Fountain.Shapes.conversation(%{"id" => id, "status" => "idle"})}
    end)

    stub(Ravix.Previews, :prepare_agent_preview, fn _ ->
      send(parent, {:preparing, self()})
      receive do: (:continue -> "")
    end)

    expect(Fountain, :prompt, fn _, _, _, _, opts ->
      assert opts[:client_request_id] == row.id
      :ok
    end)

    server = server()
    tick = Task.async(fn -> Server.tick(server) end)
    assert_receive {:preparing, preparer}, 2000
    Store.get(row.id) |> Ecto.Changeset.change(claimed_by: "undiscovered@host") |> Repo.update!()
    Store.recover()
    assert Store.get(row.id).status == :unconfirmed
    send(preparer, :continue)
    assert :ok = Task.await(tick)
    assert Store.get(row.id).status == :queued

    stub(Ravix.Previews, :prepare_agent_preview, fn _ -> "" end)
    Server.tick(server)
    assert Store.get(row.id).status == :sent
    Server.tick(server)
  end

  test "release cannot reset POSTs or a newer claim", c do
    row = enqueue(c, "guarded")
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()
    assert Store.claim(row.id, first)
    Store.release_claim(row.id, first)
    assert Store.claim(row.id, second)
    Store.release_claim(row.id, first)
    assert Store.get(row.id).status == :sending
    refute Store.begin_post(row.id, first)
    assert Store.begin_post(row.id, second)
    Store.release_claim(row.id, second)
    assert Store.get(row.id).status == :sending
  end

  defp enqueue(c, conversation) do
    track = insert_track(project: c.project, conversation_id: conversation)

    {:ok, row} =
      Store.enqueue(track.id, c.user.id, c.user.login, Ecto.UUID.generate(), %PromptQueue.Body{
        prompt: "durable",
        images: []
      })

    row
  end

  defp server do
    spec =
      Supervisor.child_spec({Server, name: nil, interval: false},
        id: make_ref(),
        restart: :temporary
      )

    server = start_supervised!(spec)
    Sandbox.allow(Repo, self(), server)
    for mod <- [Fountain, Ravix.Projects, Ravix.Previews], do: allow(mod, self(), server)
    server
  end
end
