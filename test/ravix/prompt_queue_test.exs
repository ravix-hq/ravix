defmodule Ravix.PromptQueueTest do
  use Ravix.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Ravix.Fountain.{Error, FakeTransport}
  alias Ravix.Fountain.Shapes
  alias Ravix.Hub
  alias Ravix.Hub.Event
  alias Ravix.PromptQueue
  alias Ravix.PromptQueue.{Item, Server}
  alias Ravix.QueryCount
  alias Ravix.Tracks.TrackMember

  # ── fixture ───────────────────────────────────────────────────────────

  setup do
    owner = insert_user()
    guest = insert_user()
    stranger = insert_user()

    # No repository: the clone credential is Projects' business and is stubbed.
    project =
      insert_project(user: owner, repo_full_name: nil, vault_id: nil, installation_id: nil)

    track = insert_track(project: project, conversation_id: "c1", created_by_login: owner.login)

    stub(Ravix.Projects, :prepare_machine, fn _project, _client -> :ok end)
    server = start_server()

    %{
      owner: owner,
      guest: guest,
      stranger: stranger,
      project: project,
      track: track,
      server: server
    }
  end

  # A worker of this test's own, on this test's sandbox connection and Mimic
  # stubs (its delivery tasks inherit both through `$callers`).
  defp start_server(opts \\ []) do
    spec =
      Supervisor.child_spec({Server, Keyword.merge([name: nil, interval: false], opts)},
        id: make_ref()
      )

    pid = start_supervised!(spec)
    Sandbox.allow(Repo, self(), pid)

    for mod <- [Ravix.Fountain, Ravix.Projects, Ravix.Previews, Ravix.Previews.Store],
        do: allow(mod, self(), pid)

    pid
  end

  # A scripted Fountain behind `Ravix.Fountain.client/0`.
  defp fountain(expectations, opts \\ []) do
    client = FakeTransport.client(expectations, opts)
    stub(Ravix.Fountain, :client, fn -> client end)
    client
  end

  # A stub of `Ravix.Fountain.get_conversation/2` must answer what the real one
  # answers, so it is built by the same function the real one builds it with.
  # A map literal here compiles, and hides every field the delivery path reads.
  defp conversation(raw), do: Shapes.conversation(raw)

  # The same, with the two calls the worker makes answered by functions
  # instead of a script: `on_read` returns the conversation's status,
  # `on_post` returns the POST's outcome. Both run inside the delivery task.
  defp fountain_hooks(on_read, on_post) do
    test = self()
    fountain([], verify: false)

    stub(Ravix.Fountain, :get_conversation, fn _client, id ->
      {:ok, conversation(%{"id" => id, "status" => on_read.()})}
    end)

    stub(Ravix.Fountain, :prompt, fn _client, id, text, images, _opts ->
      send(test, {:posted, id, %{"prompt" => text, "images" => images}})
      on_post.()
    end)
  end

  defp read(status),
    do:
      {%{method: "GET", path: "/api/conversations/c1"},
       {200, [], %{data: %{id: "c1", status: status}}}}

  defp read_fails,
    do: {%{method: "GET", path: "/api/conversations/c1"}, {503, [], %{error: "offline"}}}

  defp accept,
    do:
      {%{method: "POST", path: "/api/conversations/c1/prompts"}, {202, [], %{data: %{ok: true}}}}

  # `GET /turns`, with a turn for each `client_request_id` given.
  defp turns(request_ids) do
    turns =
      request_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {id, n} ->
        %{id: "t#{n}", prompt: "p", status: "completed", client_request_id: id}
      end)

    {%{method: "GET", path: "/api/conversations/c1/turns"}, {200, [], %{data: turns}}}
  end

  defp refuse(status, code),
    do: {%{method: "POST", path: "/api/conversations/c1/prompts"}, {status, [], %{error: code}}}

  defp posted(client) do
    client |> FakeTransport.calls() |> Enum.filter(&(&1.method == "POST")) |> Enum.map(& &1.body)
  end

  # What the hooks reported, oldest first.
  defp hooked_posts(acc \\ []) do
    receive do
      {:posted, _id, body} -> hooked_posts([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp request_id, do: Ecto.UUID.generate()

  defp send_prompt(track, user, text, opts \\ []) do
    id = Keyword.get(opts, :id, request_id())
    images = Keyword.get(opts, :images, [])
    PromptQueue.Store.enqueue(track.id, user.id, user.login, id, %{prompt: text, images: images})
  end

  defp close(track) do
    PromptQueue.Store.cancel_track(track.id)
    Repo.update!(Ecto.Changeset.change(track, closed_at: DateTime.utc_now()))
  end

  defp preview_hook(_track, fun) do
    test = self()
    stub(Ravix.Previews, :prepare_agent_preview, fun)

    stub(Ravix.Previews.Store, :revoke_agent, fn track_id, _user_id ->
      send(test, {:revoked_agent, track_id})
      :ok
    end)
  end

  defp status_of(id), do: PromptQueue.Store.get(id).status

  # Backdate a claim so recovery treats it as one no task can still hold.
  defp age_claim(id, by_ms) do
    Ravix.Repo.update_all(
      Ecto.Query.from(p in Ravix.PromptQueue.Item, where: p.id == ^id),
      set: [claimed_at: DateTime.add(DateTime.utc_now(), -by_ms, :millisecond)]
    )
  end

  # ── delivery ──────────────────────────────────────────────────────────

  test "acknowledged prompts and images survive a restart and deliver without a browser", f do
    image = %{"media_type" => "image/png", "data" => "aGVsbG8="}

    client =
      fountain([read("running"), read("idle"), accept(), read("running"), read("idle"), accept()])

    assert {:ok, %Item{id: first, status: :queued}} =
             send_prompt(f.track, f.owner, "first", images: [image])

    assert {:ok, %Item{id: second}} = send_prompt(f.track, f.owner, "second")

    Server.tick(f.server)
    assert posted(client) == []

    # The server restarts: a new worker, recovering before its first sweep.
    restarted = start_server()
    Server.tick(restarted)
    # Each carries its row id, which Fountain copies onto the turn it opens.
    assert posted(client) == [
             %{"prompt" => "first", "images" => [image], "client_request_id" => first}
           ]

    Server.tick(restarted)
    assert length(posted(client)) == 1

    Server.tick(restarted)
    assert [_first, %{"prompt" => "second", "client_request_id" => ^second}] = posted(client)
    assert PromptQueue.Store.queued_prompts() == []
  end

  test "existing conversations receive preview instructions, and helper failure does not strand a prompt",
       f do
    fountain_hooks(fn -> "idle" end, fn -> :ok end)

    {:ok, helper} =
      Agent.start_link(fn ->
        "[ravix preview tools for this turn]\nUse sh helper.sh\n[/ravix preview tools]"
      end)

    preview_hook(f.track, fn _row -> Agent.get(helper, & &1) end)

    send_prompt(f.track, f.owner, "Set up a preview")
    Server.tick(f.server)
    assert [%{"prompt" => prompt}] = hooked_posts()
    assert String.starts_with?(prompt, "[ravix preview tools for this turn]\n")
    assert String.ends_with?(prompt, "[/ravix preview tools]\n\nSet up a preview")

    Agent.update(helper, fn _ ->
      "[ravix preview tools for this turn]\nThe preview helper could not be prepared this turn.\n[/ravix preview tools]"
    end)

    send_prompt(f.track, f.owner, "Keep working")
    Server.tick(f.server)
    assert [%{"prompt" => prompt}] = hooked_posts()
    assert prompt =~ "could not be prepared"
    assert String.ends_with?(prompt, "\n\nKeep working")
    assert PromptQueue.Store.queued_prompts() == []
  end

  test "access revoked while the helper is prepared cancels the prompt and its grant", f do
    fountain_hooks(fn -> "idle" end, fn -> :ok end)
    insert_track_member(f.track, f.guest)
    {:ok, _} = send_prompt(f.track, f.guest, "guest work", id: id = request_id())
    guest_id = f.guest.id

    preview_hook(f.track, fn _row ->
      Repo.delete_all(from(m in TrackMember, where: m.user_id == ^guest_id))
      ""
    end)

    Server.tick(f.server)
    assert hooked_posts() == []
    assert status_of(id) == :cancelled
    assert_receive {:revoked_agent, track_id}
    assert track_id == f.track.id
  end

  test "retries of the same request id use the same receipt before and after delivery", f do
    client = fountain([read("idle"), accept()])
    id = request_id()

    assert {:ok, %Item{id: ^id}} = send_prompt(f.track, f.owner, "only once", id: id)
    assert {:ok, %Item{id: ^id}} = send_prompt(f.track, f.owner, "only once", id: id)
    assert length(PromptQueue.Store.queued_prompts()) == 1

    Server.tick(f.server)

    assert {:ok, %Item{id: ^id, status: :sent}} =
             send_prompt(f.track, f.owner, "only once", id: id)

    Server.tick(f.server)

    assert length(posted(client)) == 1
    assert PromptQueue.Store.get(id).payload == ""
  end

  test "cancellation survives restart and does not block the next prompt", f do
    client = fountain([read("idle"), accept()])
    id = request_id()
    send_prompt(f.track, f.owner, "cancel me", id: id)
    send_prompt(f.track, f.owner, "keep me")

    assert :ok = PromptQueue.cancel(f.owner, f.track.id, id)
    assert PromptQueue.Store.get(id).payload == ""

    PromptQueue.Store.recover()
    Server.tick(start_server())
    assert [%{"prompt" => "keep me"}] = posted(client)
  end

  test "revoked membership and closed tracks cannot dispatch saved work", f do
    fountain_hooks(fn -> "idle" end, fn -> :ok end)
    insert_track_member(f.track, f.guest)
    {:ok, %Item{id: guest_id}} = send_prompt(f.track, f.guest, "guest work")
    Repo.delete_all(from(m in TrackMember, where: m.user_id == ^f.guest.id))

    Server.tick(f.server)
    assert hooked_posts() == []
    assert status_of(guest_id) == :cancelled

    {:ok, %Item{id: owner_id}} = send_prompt(f.track, f.owner, "owner work")
    Repo.update!(Ecto.Changeset.change(f.track, closed_at: DateTime.utc_now()))
    Server.tick(f.server)
    assert hooked_posts() == []
    assert status_of(owner_id) == :cancelled
  end

  test "cancelling during the readiness check prevents the subsequent POST", f do
    id = request_id()
    send_prompt(f.track, f.owner, "cancel during read", id: id)
    owner = f.owner
    track_id = f.track.id

    fountain_hooks(
      fn ->
        :ok = PromptQueue.cancel(owner, track_id, id)
        "idle"
      end,
      fn -> :ok end
    )

    Server.tick(f.server)
    assert hooked_posts() == []
    assert status_of(id) == :cancelled
  end

  test "a failed readiness check retries safely without losing the prompt", f do
    client = fountain([read_fails(), read("idle"), accept()])
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "after outage")

    capture_log(fn -> Server.tick(f.server) end)

    assert %Item{status: :queued, error: "Waiting for the machine connection." <> _} =
             PromptQueue.Store.get(id)

    assert posted(client) == []

    Server.tick(f.server)
    assert [%{"prompt" => "after outage"}] = posted(client)
    assert PromptQueue.Store.get(id).error == nil
  end

  test "capacity races retry, while ambiguous delivery holds later work for review", f do
    client =
      fountain([
        read("idle"),
        refuse(409, "sandbox_at_capacity"),
        read("idle"),
        refuse(502, "bad_gateway"),
        turns(["somebody-elses-prompt"]),
        read("idle"),
        accept()
      ])

    id = request_id()
    send_prompt(f.track, f.owner, "first", id: id)
    send_prompt(f.track, f.owner, "second")

    capture_log(fn -> Server.tick(f.server) end)
    assert status_of(id) == :queued

    capture_log(fn -> Server.tick(f.server) end)

    assert %Item{status: :unconfirmed, error: "Delivery could not be confirmed." <> _} =
             PromptQueue.Store.get(id)

    # Looked for once on Fountain's turns, not found, and still not sent.
    count = length(posted(client))
    Server.tick(f.server)
    assert length(posted(client)) == count

    assert %Item{status: :unconfirmed, error: "Fountain has no turn carrying" <> _} =
             PromptQueue.Store.get(id)

    # Once: the next sweep does not read the turns again (the script would
    # refuse the request).
    Server.tick(f.server)
    assert length(posted(client)) == count

    assert :ok = PromptQueue.retry(f.owner, f.track.id, id)
    Server.tick(f.server)
    assert %{"prompt" => "first"} = List.last(posted(client))
    assert status_of(id) == :sent
  end

  test "a refusal that is not a capacity problem fails the prompt for a person to retry", f do
    client = fountain([read("idle"), refuse(422, "invalid_prompt"), read("idle"), accept()])
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "refused")

    capture_log(fn -> Server.tick(f.server) end)
    assert %Item{status: :failed, error: "Delivery was refused." <> _} = PromptQueue.Store.get(id)

    assert :ok = PromptQueue.retry(f.owner, f.track.id, id)
    Server.tick(f.server)
    assert [%{"prompt" => "refused"}, %{"prompt" => "refused"}] = posted(client)
  end

  test "an ended conversation fails the prompt with directions", f do
    fountain([read("terminated")])
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "too late")

    Server.tick(f.server)

    assert %Item{status: :failed, error: "This conversation has ended." <> _} =
             PromptQueue.Store.get(id)
  end

  test "a conversation that never ran a turn says why, not \"start a new track\"", f do
    # The circular case (#35): a machine that could not be built ends the
    # conversation, and telling somebody to start a new track sends them to a
    # track that fails identically. What breaks the circle is Fountain's reason.
    reason =
      ~s({:denied, {:http, 403, %{"error" => "Add a credit card to start using Sprites."}}})

    fountain([], verify: false)

    stub(Ravix.Fountain, :get_conversation, fn _client, id ->
      {:ok, conversation(%{"id" => id, "status" => "failed", "turn_count" => 0})}
    end)

    stub(Ravix.Fountain, :events, fn _client, _id ->
      {:ok,
       [
         %{"id" => 1, "kind" => "stage", "stage" => "provision", "state" => "started"},
         %{
           "id" => 2,
           "kind" => "stage",
           "stage" => "provision",
           "state" => "failed",
           "data" => Jason.encode!(%{reason: reason})
         }
       ]}
    end)

    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "hello")
    Server.tick(f.server)

    assert %Item{status: :failed, error: error} = PromptQueue.Store.get(id)
    assert error =~ "could not be started"
    assert error =~ "Add a credit card"
    refute error =~ "Start a new track"
  end

  test "a conversation that never ran and gave no reason still avoids the circular advice", f do
    fountain([], verify: false)

    stub(Ravix.Fountain, :get_conversation, fn _client, id ->
      {:ok, conversation(%{"id" => id, "status" => "failed", "turn_count" => 0})}
    end)

    stub(Ravix.Fountain, :events, fn _client, _id -> {:error, :unavailable} end)

    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "hello")
    Server.tick(f.server)

    assert %Item{status: :failed, error: error} = PromptQueue.Store.get(id)
    assert error =~ "could not be started"
    refute error =~ "Start a new track"
  end

  test "a conversation that did run turns still gets the directions", f do
    fountain([], verify: false)

    stub(Ravix.Fountain, :get_conversation, fn _client, id ->
      {:ok, conversation(%{"id" => id, "status" => "terminated", "turn_count" => 7})}
    end)

    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "too late")
    Server.tick(f.server)

    assert %Item{status: :failed, error: "This conversation has ended." <> _} =
             PromptQueue.Store.get(id)
  end

  test "a claim outliving its task recovers as unconfirmed, never an automatic replay", f do
    client = fountain([])
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "might already have run")
    assert PromptQueue.Store.claim(id)
    assert status_of(id) == :sending

    # A claim old enough that nothing can still be working on it.
    age_claim(id, PromptQueue.Store.claim_timeout_ms() + 1_000)

    PromptQueue.Store.recover()

    assert %Item{status: :unconfirmed, error: "The server restarted during delivery." <> _} =
             PromptQueue.Store.get(id)

    FakeTransport.expect(
      client,
      %{method: "GET", path: "/api/conversations/c1/turns"},
      {200, [], %{data: []}}
    )

    Server.tick(start_server())
    assert posted(client) == []

    assert %Item{status: :unconfirmed, error: "Fountain has no turn carrying" <> _} =
             PromptQueue.Store.get(id)

    assert PromptQueue.Store.get(id).payload != ""
  end

  test "an unconfirmed prompt Fountain has a turn for is recorded as delivered, not re-sent", f do
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "did this arrive?")
    client = fountain([turns(["somebody-elses-prompt", id])])
    PromptQueue.Store.set_status(id, :unconfirmed, "Delivery could not be confirmed.")
    Hub.subscribe(f.project.id)

    Server.tick(f.server)

    assert %Item{status: :sent, error: nil, payload: ""} = PromptQueue.Store.get(id)
    assert posted(client) == []
    assert_receive {:hub, %Event{name: :turn}}
  end

  test "a turns read that fails leaves an unconfirmed prompt for the next sweep", f do
    fountain([
      {%{method: "GET", path: "/api/conversations/c1/turns"}, {503, [], %{error: "offline"}}},
      turns([])
    ])

    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "unknown")
    PromptQueue.Store.set_status(id, :unconfirmed, "Delivery could not be confirmed.")

    capture_log(fn -> Server.tick(f.server) end)

    assert %Item{status: :unconfirmed, error: "Delivery could not be confirmed."} =
             PromptQueue.Store.get(id)

    Server.tick(f.server)

    assert %Item{status: :unconfirmed, error: "Fountain has no turn carrying" <> _} =
             PromptQueue.Store.get(id)
  end

  test "annotating an unconfirmed row does not undo a retry that got there first", f do
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "retried")
    PromptQueue.Store.set_status(id, :unconfirmed, "Delivery could not be confirmed.")
    assert :ok = PromptQueue.retry(f.owner, f.track.id, id)

    PromptQueue.Store.annotate(id, :unconfirmed, "too late")
    assert %Item{status: :queued, error: nil} = PromptQueue.Store.get(id)

    PromptQueue.Store.set_status(id, :unconfirmed, "Delivery could not be confirmed.")
    PromptQueue.Store.annotate(id, :unconfirmed, "found nothing")
    assert %Item{status: :unconfirmed, error: "found nothing"} = PromptQueue.Store.get(id)
  end

  test "a fresh claim is left to the task still holding it", f do
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "still in flight")
    assert PromptQueue.Store.claim(id)

    # The delivery tasks are supervised beside the server rather than under
    # it, so they outlive its restart; recovering their rows would POST the
    # same prompt twice.
    PromptQueue.Store.recover()
    assert status_of(id) == :sending
  end

  test "project members retain authorship and a full queue refuses more work", f do
    client = fountain([read("idle"), accept()])
    insert_project_member(f.project, f.guest)
    send_prompt(f.track, f.guest, "project member work")

    Server.tick(f.server)
    assert [%{"prompt" => "[from @" <> rest}] = posted(client)
    assert rest == "#{f.guest.login}] project member work"

    for i <- 0..19, do: assert({:ok, _} = send_prompt(f.track, f.owner, "queued #{i}"))
    assert {:error, {:conflict, "queue_full", _}} = send_prompt(f.track, f.owner, "over limit")
  end

  test "a solo track is not prefixed with its own author", f do
    client = fountain([read("idle"), accept()])
    send_prompt(f.track, f.owner, "just me")
    Server.tick(f.server)
    assert [%{"prompt" => "just me"}] = posted(client)
  end

  test "the background timer advances waiting work with no subsequent client requests", f do
    fountain_hooks(fn -> "idle" end, fn -> :ok end)
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "run after I leave")

    start_server(interval: 20)
    deadline = System.monotonic_time(:millisecond) + 3_500
    wait_until(fn -> status_of(id) == :sent end, deadline)

    assert status_of(id) == :sent
    assert [%{"prompt" => "run after I leave"}] = hooked_posts()
  end

  defp wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      true ->
        Process.sleep(10)
        wait_until(fun, deadline)
    end
  end

  test "a sweep reads a busy conversation once, however many prompts wait on it", f do
    # One expectation, so a second read would be a request nothing scripted:
    # the fake answers it with an error and fails the test at exit.
    client = fountain([read("running")])
    for n <- 1..5, do: send_prompt(f.track, f.owner, "waiting #{n}")

    Server.tick(f.server)

    assert [%{method: "GET", path: "/api/conversations/c1"}] = FakeTransport.calls(client)

    waiting = PromptQueue.Store.queued_prompts(f.track.id)
    assert length(waiting) == 5
    assert Enum.all?(waiting, &(&1.status == :queued))
  end

  test "delivering a head reads its track and project only where access is decided", f do
    fountain_hooks(fn -> "idle" end, fn -> :ok end)
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "counted")

    # The sweep hands each head to a task of its own, so the count follows
    # the server into them rather than watching the caller of `tick/1`.
    {_result, queries} =
      QueryCount.count(fn -> Server.tick(f.server) end, from: {:callers, f.server})

    assert status_of(id) == :sent

    # Who may send is established three times, on purpose: the door, then
    # again just before the claim and just before the POST, because
    # membership and cancellation can change during the network calls in
    # between. Each is `Access.track_access/2`, which is the track and the
    # project once. Delivery itself used to read both a fourth time, having
    # been handed neither. The two further reads of `tracks` are the
    # publishes: `Store.claim/1` and `Store.mark_delivered/1` each tell the
    # project's hub, and find the project through the track.
    assert Enum.count(queries, &(&1 == "projects")) == 3
    assert Enum.count(queries, &(&1 == "tracks")) == 3 + 2
  end

  test "the sweep's two reads are answered from the indexes made for them" do
    # Without the two partial indexes both of these read the whole table, and
    # the whole table is nearly all delivered rows. A plan is the only thing
    # that can show they are used: the seq scan is switched off for this
    # transaction so that a table this small does not hide the choice. An
    # index is named in a plan only when it is scanned; whether as an ordered
    # scan or a bitmap one is the planner's call on the statistics of the
    # moment, and either reads only the rows the index holds.
    Repo.query!("SET LOCAL enable_seqscan = off")

    assert plan(fn -> PromptQueue.Store.heads() end) =~ "prompt_queue_thread_heads"
    assert plan(fn -> PromptQueue.Store.recover() end) =~ "prompt_queue_sending_claims"
  end

  # The plan Postgres has for the first query `fun` runs, with its parameters.
  defp plan(fun) do
    id = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach(
      id,
      [:ravix, :repo, :query],
      fn _event, _measure, meta, _config ->
        if self() == test, do: send(test, {id, meta.query, meta.params})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    assert_receive {^id, sql, params}

    %{rows: rows} = Repo.query!("EXPLAIN " <> sql, params)
    Enum.map_join(rows, "\n", &List.first/1)
  end

  test "one track needing attention does not block another track", f do
    other = insert_track(project: f.project, conversation_id: "c2")
    test = self()
    fountain([], verify: false)

    stub(Ravix.Fountain, :get_conversation, fn _client, id ->
      {:ok, conversation(%{"id" => id, "status" => "idle"})}
    end)

    stub(Ravix.Fountain, :prompt, fn _client, id, text, _images, _opts ->
      send(test, {:posted, id, text})
      :ok
    end)

    {:ok, %Item{id: blocked}} = send_prompt(f.track, f.owner, "blocked")
    PromptQueue.Store.set_status(blocked, :unconfirmed, "Check delivery")
    send_prompt(other, f.owner, "independent work")

    Server.tick(f.server)
    assert_receive {:posted, "c2", "independent work"}
    refute_receive {:posted, "c1", _}
    assert status_of(blocked) == :unconfirmed
  end

  test "a late delivery failure cannot resurrect a closed track's queue", f do
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "closing")
    track = f.track

    fountain_hooks(fn -> "idle" end, fn ->
      close(track)
      {:error, %Error{status: 409, code: "sandbox_at_capacity", message: "busy", kind: :api}}
    end)

    Server.tick(f.server)
    assert %Item{status: :cancelled, payload: ""} = PromptQueue.Store.get(id)
  end

  test "credential failures hold the prompt until the machine can be prepared", f do
    client = fountain([read("idle"), read("idle"), read("idle"), accept()])
    {:ok, failures} = Agent.start_link(fn -> 2 end)

    stub(Ravix.Projects, :prepare_machine, fn _project, _client ->
      Agent.get_and_update(failures, fn
        0 -> {:ok, 0}
        n -> {{:error, {:unavailable, "mint unavailable"}}, n - 1}
      end)
    end)

    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "Push my changes")

    Server.tick(f.server)
    assert posted(client) == []

    assert %Item{status: :queued, error: "Waiting for the machine connection." <> _} =
             PromptQueue.Store.get(id)

    Server.tick(f.server)
    assert posted(client) == []
    assert status_of(id) == :queued

    Server.tick(f.server)
    assert [%{"prompt" => "Push my changes"}] = posted(client)
    assert PromptQueue.Store.queued_prompts() == []
  end

  test "an unconfigured Fountain leaves the queue untouched", f do
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "waiting for a key")
    Server.tick(f.server)
    assert status_of(id) == :queued
  end

  # ── the person's side ─────────────────────────────────────────────────

  test "queue routes respect membership and only sender or owner can cancel", f do
    insert_track_member(f.track, f.guest)
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "owner's prompt")

    assert {:error, :not_found} = PromptQueue.list(f.stranger, f.track.id)
    assert {:error, :not_found} = PromptQueue.cancel(f.stranger, f.track.id, id)

    assert {:error, {:forbidden, "Only the sender or project owner can cancel" <> _}} =
             PromptQueue.cancel(f.guest, f.track.id, id)

    assert {:ok, [%{id: ^id, can_cancel: false, status: :queued, image_count: 0}]} =
             PromptQueue.list(f.guest, f.track.id)

    assert {:ok, [%{id: ^id, can_cancel: true, prompt: "owner's prompt"}]} =
             PromptQueue.list(f.owner, f.track.id)

    {:ok, %Item{id: guest_id}} = send_prompt(f.track, f.guest, "guest's prompt")

    assert {:ok, [_, %{id: ^guest_id, can_cancel: true, author_login: login}]} =
             PromptQueue.list(f.guest, f.track.id)

    assert login == f.guest.login
    assert :ok = PromptQueue.cancel(f.owner, f.track.id, guest_id)
    assert {:ok, [%{id: ^id}]} = PromptQueue.list(f.owner, f.track.id)
  end

  test "a prompt being delivered cannot be cancelled, and only a refused one can be retried", f do
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "in flight")
    assert {:error, {:conflict, "not_failed", _}} = PromptQueue.retry(f.owner, f.track.id, id)

    assert PromptQueue.Store.claim(id)

    assert {:error, {:conflict, "already_sending", _}} =
             PromptQueue.cancel(f.owner, f.track.id, id)

    assert {:ok, [%{id: ^id, status: :sending, can_cancel: false}]} =
             PromptQueue.list(f.owner, f.track.id)

    PromptQueue.Store.set_status(id, :sent)

    assert {:error, {:conflict, "already_sending", _}} =
             PromptQueue.cancel(f.owner, f.track.id, id)

    assert {:ok, []} = PromptQueue.list(f.owner, f.track.id)

    other = insert_track(project: f.project, conversation_id: "c2")
    assert {:error, :not_found} = PromptQueue.cancel(f.owner, other.id, id)
  end

  test "a closed track's prompts cannot be retried", f do
    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "later")
    PromptQueue.Store.set_status(id, :failed, "refused")
    close(f.track)
    assert status_of(id) == :cancelled
    assert {:error, :not_found} = PromptQueue.retry(f.owner, f.track.id, id)
  end

  test "enqueue validates the request id, the receipt and the size", f do
    assert {:error, {:unprocessable, "request_id_required", _}} =
             send_prompt(f.track, f.owner, "x", id: "short")

    assert {:error, {:unprocessable, "request_id_required", _}} =
             send_prompt(f.track, f.owner, "x", id: nil)

    assert {:error, {:unprocessable, "request_id_required", _}} =
             send_prompt(f.track, f.owner, "x", id: "has space in it!!")

    id = request_id()
    assert {:ok, _} = send_prompt(f.track, f.owner, "mine", id: id)

    assert {:error, {:conflict, "request_id_used", _}} =
             send_prompt(f.track, f.guest, "theirs", id: id)

    other = insert_track(project: f.project, conversation_id: "c2")

    assert {:error, {:conflict, "request_id_used", _}} =
             send_prompt(other, f.owner, "elsewhere", id: id)

    huge = %{"media_type" => "image/png", "data" => String.duplicate("a", 12 * 1024 * 1024)}

    assert {:error, {:unprocessable, "prompt_too_large", _}} =
             send_prompt(f.track, f.owner, "big", images: [huge])

    assert {:error, :not_found} =
             PromptQueue.Store.enqueue(
               "no-such-track",
               f.owner.id,
               f.owner.login,
               request_id(),
               %{}
             )

    # Encoding happens before the transaction opens, so a payload too large
    # to store is refused for being too large rather than after a row lock
    # it was never going to use. Both refusals are still refusals; which
    # one arrives says where the work stopped.
    assert {:error, {:unprocessable, "prompt_too_large", _}} =
             PromptQueue.Store.enqueue(
               "no-such-track",
               f.owner.id,
               f.owner.login,
               request_id(),
               %{"images" => [huge]}
             )
  end

  test "summaries read the payload and string keys are accepted", f do
    image = %{"media_type" => "image/png", "data" => "aGVsbG8="}

    {:ok, %Item{id: id}} =
      PromptQueue.Store.enqueue(f.track.id, f.owner.id, f.owner.login, request_id(), %{
        "prompt" => "look",
        "images" => [image]
      })

    assert [%{id: ^id, prompt: "look", image_count: 1, status: :queued, error: nil}] =
             PromptQueue.Store.summaries(f.track.id)

    assert [%Item{id: ^id}] = PromptQueue.Store.heads()

    # The head carries neither the parsed body nor its JSON string: it is read
    # every two seconds per track, and the attachments are loaded once, just
    # before the POST.
    assert [%Item{id: ^id, body: nil, payload: nil}] = PromptQueue.Store.heads()
  end

  test "a delivered row releases its bytes and keeps its count", f do
    image = %{"media_type" => "image/png", "data" => "aGVsbG8="}

    {:ok, %Item{id: id}} =
      PromptQueue.Store.enqueue(f.track.id, f.owner.id, f.owner.login, request_id(), %{
        prompt: "look",
        images: [image, image]
      })

    assert %Item{image_count: 2} = stored = PromptQueue.Store.get(id)
    assert stored.body["prompt"] == "look"
    assert length(stored.body["images"]) == 2

    PromptQueue.Store.set_status(id, :sent)

    # The images are gone, because they are large and they have been sent.
    # The count stays, because the panel still has to say what was sent, and
    # the id stays as the receipt for a retried request.
    assert %Item{id: ^id, status: :sent, body: nil, image_count: 2} = PromptQueue.Store.get(id)
  end

  test "the body is stored as JSON the database understands, not a string", f do
    {:ok, %Item{id: id}} =
      PromptQueue.Store.enqueue(f.track.id, f.owner.id, f.owner.login, request_id(), %{
        prompt: "look",
        images: []
      })

    # Read back through the column rather than through a cast in the query,
    # which is what `summaries/1` used to need.
    assert %Item{body: %{"prompt" => "look", "images" => []}} = PromptQueue.Store.get(id)
  end

  # ── the hub ───────────────────────────────────────────────────────────

  test "every change to a track's queue and every delivery is published", f do
    fountain([read("idle"), accept()])
    Hub.subscribe(f.project.id)
    track_id = f.track.id

    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "watched")
    assert_receive {:hub, %Event{name: :queue, track_id: ^track_id}}

    Server.tick(f.server)
    # Claimed, then sent, then the turn.
    assert_receive {:hub, %Event{name: :queue, track_id: ^track_id}}
    assert_receive {:hub, %Event{name: :queue, track_id: ^track_id}}
    assert_receive {:hub, %Event{name: :turn, track_id: ^track_id}}
    assert status_of(id) == :sent

    {:ok, %Item{id: id}} = send_prompt(f.track, f.owner, "cancelled")
    assert_receive {:hub, %Event{name: :queue, track_id: ^track_id}}
    :ok = PromptQueue.cancel(f.owner, track_id, id)
    assert_receive {:hub, %Event{name: :queue, track_id: ^track_id}}

    PromptQueue.Store.cancel_track(track_id)
    assert_receive {:hub, %Event{name: :queue, track_id: ^track_id}}
  end
end
