defmodule Ravix.Tooling.HeldTasksTest do
  use Ravix.DataCase, async: false
  use Mimic
  import Ravix.ToolingFixture
  alias Ecto.Adapters.SQL.Sandbox
  alias Ravix.{Fountain, Tooling, Tracks}
  alias Ravix.PromptQueue.{Server, Store}
  alias Ravix.Tooling.Tasks

  setup do
    owner = insert_user()
    sender = insert_user()

    project =
      insert_project(user: owner, repo_full_name: nil, vault_id: nil, installation_id: nil)

    insert_project_member(project, sender)
    track = insert_track(project: project, conversation_id: Ecto.UUID.generate())
    {p, _, _} = principal(sender)
    {owner_p, _, _} = principal(owner)
    stub(Fountain, :client, fn -> Fountain.Client.new("https://fountain.test", "key") end)
    owner_pid = self()
    stub(Tracks, :follow, fn _, _, _ -> {:ok, owner_pid} end)
    {:ok, head} = Tasks.send(p, track.id, "first", "head")
    {:ok, next} = Tasks.send(p, track.id, "next", "next")
    %{p: p, owner: owner_p, track: track, project: project, head: head, next: next}
  end

  test "get and wait expose unconfirmed heads and blocked successors without Fountain", c do
    Store.set_status(c.head.id, :unconfirmed, "Delivery could not be confirmed.")
    reject(Fountain, :turns, 2)
    assert {:ok, head} = Tooling.call(c.p, "get_task", %{"task_id" => c.head.id})
    assert head.status.state == "TASK_STATE_INPUT_REQUIRED"
    assert [%{text: "Delivery could not be confirmed."}] = head.status.message.parts
    assert {:ok, next} = Tooling.call(c.p, "get_task", %{"task_id" => c.next.id})
    assert next.status.state == "TASK_STATE_SUBMITTED"

    assert hd(next.status.message.parts).text ==
             "Waiting behind an unconfirmed prompt #{c.head.id}."

    assert {:ok, %{changed: ids, stale: false}} =
             Tooling.call(c.p, "wait_task", %{
               "task_ids" => [c.head.id, c.next.id],
               "timeout_ms" => 1000
             })

    assert ids == [c.head.id, c.next.id]
  end

  test "legacy state acknowledgements do not repeatedly report an unchanged blocked task", c do
    Store.set_status(c.head.id, :unconfirmed, "Check the transcript.")

    args = %{
      "task_ids" => [c.next.id],
      "since" => %{c.next.id => "TASK_STATE_SUBMITTED"},
      "timeout_ms" => 0
    }

    for _ <- 1..2 do
      assert {:ok, %{changed: [], tasks: [next]}} = Tooling.call(c.p, "wait_task", args)
      assert next.status.state == "TASK_STATE_SUBMITTED"
      assert hd(next.status.message.parts).text =~ c.head.id
    end

    assert {:ok, _} = Tasks.cancel(c.p, c.next.id)
    assert {:ok, %{changed: [id]}} = Tooling.call(c.p, "wait_task", args)
    assert id == c.next.id
  end

  test "a queue transition wakes an active waiter even when a blocked task stays submitted", c do
    {:ok, before} = Tasks.get(c.p, c.next.id)

    waiter =
      Task.async(fn ->
        Tooling.call(c.p, "wait_task", %{
          "task_ids" => [c.next.id],
          "since" => %{c.next.id => Tasks.version(before)},
          "timeout_ms" => 2000
        })
      end)

    wait_subscribed(c.project.id, waiter.pid)
    Store.set_status(c.head.id, :unconfirmed, "Check the transcript.")
    assert {:ok, {:ok, %{changed: [id], tasks: [next]}}} = Task.yield(waiter, 1000)
    assert id == c.next.id
    assert next.status.state == "TASK_STATE_SUBMITTED"
    assert hd(next.status.message.parts).text =~ c.head.id
  end

  test "reason changes wake an acknowledged input-required task", c do
    Store.set_status(c.head.id, :unconfirmed, "Delivery could not be confirmed.")
    {:ok, before} = Tasks.get(c.p, c.head.id)

    waiter =
      Task.async(fn ->
        Tooling.call(c.p, "wait_task", %{
          "task_ids" => [c.head.id],
          "since" => %{c.head.id => Tasks.version(before)},
          "timeout_ms" => 2000
        })
      end)

    wait_subscribed(c.project.id, waiter.pid)
    Store.annotate(c.head.id, :unconfirmed, "Fountain has no turn carrying this prompt's id.")
    assert {:ok, {:ok, %{changed: [_], tasks: [head]}}} = Task.yield(waiter, 1000)
    assert hd(head.status.message.parts).text =~ "no turn"
  end

  for actor <- [:p, :owner] do
    test "#{actor} can cancel an unconfirmed head and the next sweep delivers its successor", c do
      Store.set_status(c.head.id, :unconfirmed, "Unconfirmed")

      assert {:ok, %{status: %{state: "TASK_STATE_CANCELED"}}} =
               Tooling.call(c[unquote(actor)], "cancel_task", %{"task_id" => c.head.id})

      assert Store.get(c.head.id).status == :cancelled
      stub(Ravix.Projects, :prepare_machine, fn _, _ -> :ok end)
      stub(Ravix.Previews, :prepare_agent_preview, fn _ -> "" end)

      stub(Fountain, :get_conversation, fn _, id ->
        {:ok, Fountain.Shapes.conversation(%{"id" => id, "status" => "idle"})}
      end)

      expect(Fountain, :prompt, fn _, _, _, _, opts ->
        assert opts[:client_request_id] == c.next.id
        :ok
      end)

      server = start_supervised!({Server, name: nil, interval: false})
      Sandbox.allow(Repo, self(), server)
      for mod <- [Fountain, Ravix.Projects, Ravix.Previews], do: allow(mod, self(), server)
      Server.tick(server)
      assert Store.get(c.next.id).status == :sent
    end
  end

  test "failed rows include their reason and can be retried or canceled; sending cannot", c do
    Store.set_status(c.head.id, :failed, "Delivery refused: setup is invalid.")
    assert {:ok, head} = Tooling.call(c.p, "get_task", %{"task_id" => c.head.id})
    assert head.status.state == "TASK_STATE_FAILED"
    assert hd(head.status.message.parts).text =~ "setup is invalid"

    assert {:ok, %{status: %{state: "TASK_STATE_SUBMITTED"}}} =
             Tooling.call(c.p, "retry_task", %{"task_id" => c.head.id})

    assert Store.get(c.head.id).status == :queued
    assert Store.get(c.head.id).error == nil
    assert Store.claim(c.head.id)
    assert {:error, {:conflict, "task_not_cancelable", _}} = Tasks.cancel(c.p, c.head.id)
    assert {:error, {:conflict, "not_failed", _}} = Tasks.retry(c.p, c.head.id)
    Store.set_status(c.head.id, :failed, "refused")
    assert {:ok, _} = Tasks.cancel(c.owner, c.head.id)
  end

  test "a web retry can recover a failed receipt written by an older version", c do
    task = Repo.get!(Ravix.Tooling.Task, c.head.id)
    task |> Ecto.Changeset.change(state: "TASK_STATE_FAILED") |> Repo.update!()
    Store.set_status(c.head.id, :failed, "refused")
    assert :ok = Ravix.PromptQueue.retry(c.p.user, c.track.id, c.head.id)
    Store.mark_delivered(c.head.id)

    stub(Fountain, :turns, fn _, _ ->
      {:ok,
       [
         Fountain.Shapes.turn(%{
           "id" => "turn",
           "client_request_id" => c.head.id,
           "status" => "completed"
         })
       ]}
    end)

    stub(Fountain, :events_page, fn _, _, _ ->
      {:ok, %{events: [], next_cursor: nil, has_more: false}}
    end)

    assert {:ok, %{state: "TASK_STATE_COMPLETED"}} = Tasks.get(c.p, c.head.id)
  end

  test "another principal and missing mutation scopes cannot clear the head", c do
    other = insert_user()
    insert_project_member(c.project, other)
    {other_p, _, _} = principal(other)
    Store.set_status(c.head.id, :unconfirmed, "Unconfirmed")
    assert {:error, {:forbidden, _}} = Tasks.cancel(other_p, c.head.id)
    assert {:error, {:forbidden, _}} = Tasks.retry(other_p, c.head.id)
    assert {:error, :not_found} = Tasks.get(other_p, c.head.id)
    {read_only, _, _} = principal(c.p.user, "mcp", ["tracks:read"])

    for tool <- ["cancel_task", "retry_task"] do
      assert {:error, {:forbidden, _}} = Tooling.call(read_only, tool, %{"task_id" => c.head.id})
    end

    assert Store.get(c.head.id).status == :unconfirmed
  end

  defp wait_subscribed(project_id, owner, tries \\ 500)
  defp wait_subscribed(_, _, 0), do: flunk("waiter did not subscribe")

  defp wait_subscribed(project_id, owner, tries) do
    if Enum.any?(Registry.lookup(Ravix.PubSub, Ravix.Hub.topic(project_id)), fn {pid, _} ->
         pid != owner and
           Process.info(pid, :dictionary) |> elem(1) |> Keyword.get(:"$initial_call") ==
             {Ravix.Tooling.Wait, :init, 1}
       end) do
      :ok
    else
      Process.sleep(2)
      wait_subscribed(project_id, owner, tries - 1)
    end
  end
end
