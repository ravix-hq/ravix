defmodule Ravix.Tracks.ReplyTest do
  use Ravix.DataCase, async: true
  import Mimic

  alias Ravix.{Fountain, Hub, QueryCount, Repo, Tracks}
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Tracks.{Reply, Settlement, Thread}
  alias Ravix.Tracks.Transcript.{Block, Event}
  alias Ravix.TranscriptFixture, as: TF

  setup :verify_on_exit!

  defp text(body), do: %Block.Text{body: body, started_at: nil, ended_at: nil}

  describe "excerpt/1" do
    test "is the first two lines of the last text, as plain words" do
      blocks = [
        text("Looking at the tests first."),
        %Block.Thinking{body: "hmm", started_at: nil, ended_at: nil},
        text("""
        ## Fixed the **login** redirect

        - It now returns to [the page](https://example.test/x) you came from.
        ```elixir
        IO.puts(:hidden)
        ```
        A third line nobody sees.
        """)
      ]

      assert Reply.excerpt(blocks) ==
               "Fixed the login redirect It now returns to the page you came from."
    end

    test "keeps markup as text for the page to escape" do
      assert Reply.excerpt([text("<script>alert(1)</script> done")]) ==
               "<script>alert(1)</script> done"
    end

    test "is bounded, and says where it was cut" do
      excerpt = Reply.excerpt([text(String.duplicate("word ", 200))])
      assert String.length(excerpt) <= 200
      assert String.ends_with?(excerpt, "…")
    end

    test "is nil for a reply with nothing to say in text" do
      assert Reply.excerpt([]) == nil
      assert Reply.excerpt([text("```\ncode only\n```"), text("---")]) == nil
    end
  end

  describe "stale?/1" do
    test "asks only about a settled thread whose kept reply predates its activity" do
      now = DateTime.utc_now()
      earlier = DateTime.add(now, -60)
      thread = %{status: :ready, last_active_at: now, reply_at: nil}

      assert Reply.stale?(thread)
      assert Reply.stale?(%{thread | reply_at: earlier})
      assert Reply.stale?(%{thread | status: :failed})
      refute Reply.stale?(%{thread | reply_at: now})
      refute Reply.stale?(%{thread | status: :running})
      refute Reply.stale?(%{thread | last_active_at: nil})
      refute Reply.stale?(%{id: "partial"})
    end
  end

  defp settled(turn, body, at) do
    [
      Map.put(TF.stage(1, "started"), "turn_id", turn),
      Map.put(TF.output(2, TF.text(body), turn), "ts", at),
      %{
        "id" => 3,
        "turn_id" => turn,
        "kind" => "stage",
        "stage" => "turn",
        "state" => "completed",
        "ts" => at
      }
    ]
  end

  defp thread_of(track), do: Repo.get!(Thread, track.id)

  describe "record/3 and settlement" do
    test "settlement keeps the excerpt, publishes it, and an older reply never overwrites a newer" do
      owner = insert_user()
      project = insert_project(user: owner)
      track = insert_track(project: project, conversation_id: "reply-conversation")
      client = Fountain.Client.new("https://fountain.test", "test-key")
      Hub.subscribe(project.id)

      log = settled("t2", "The **newest** reply.", "2026-09-28T16:27:00Z")
      stub(Fountain, :events, fn _, "reply-conversation", _ -> {:ok, log} end)
      event = log |> List.last() |> Event.from()

      assert {:ok, _} = Settlement.record(client, track.id, "reply-conversation", event)
      assert_receive {:hub, %{name: :reply, project_id: id}} when id == project.id

      assert %{reply_excerpt: "The newest reply.", reply_at: ~U[2026-09-28 16:27:00.000000Z]} =
               thread_of(track)

      :ok =
        Reply.record(
          "reply-conversation",
          settled("t1", "An older one", "2026-09-27T10:00:00Z"),
          "claude"
        )

      assert thread_of(track).reply_excerpt == "The newest reply."
      refute_receive {:hub, %{name: :reply}}
    end

    test "a turn with no time on it keeps nothing" do
      track = insert_track(conversation_id: "untimed")
      events = [TF.output(1, TF.text("hello")), TF.stage(2, "completed")]
      assert :ok = Reply.record("untimed", events, "claude")
      assert thread_of(track).reply_at == nil
    end
  end

  describe "backfill/2" do
    defp view_thread(track, active, overrides \\ []) do
      Map.merge(
        %{
          id: track.id,
          conversation_id: track.conversation_id,
          runtime: "claude",
          status: :ready,
          last_active_at: active,
          reply_at: nil
        },
        Map.new(overrides)
      )
    end

    defp page(events) do
      {200, [],
       %{
         data: Enum.reverse(events),
         meta: %{has_more: false},
         page: %{order: "desc", oldest_cursor: 1, newest_cursor: 3}
       }}
    end

    test "reads the newest page once and keeps its reply as of the conversation's activity" do
      track = insert_track(conversation_id: "backfilled")
      active = ~U[2026-09-28 17:00:00.000000Z]

      client =
        FakeTransport.client([
          {%{
             method: "GET",
             path: "/api/conversations/backfilled/events",
             query: %{limit: "60", order: "desc", whole_turns: "true"}
           }, page(settled("t", "Kept from the page.", "2026-09-28T16:27:00Z"))}
        ])

      assert :ok = Reply.backfill([view_thread(track, active)], client: {:ok, client})
      assert %{reply_excerpt: "Kept from the page.", reply_at: ^active} = thread_of(track)

      # Current now: a second call asks Fountain nothing (the fake is spent).
      assert :ok = Reply.backfill([view_thread(track, active)], client: {:ok, client})
      assert length(FakeTransport.calls(client)) == 1
    end

    test "a row kept since it was listed is not fetched again" do
      track = insert_track(conversation_id: "kept-meanwhile")
      active = DateTime.add(DateTime.utc_now(), -60)
      keep_reply(track, "Already here")
      client = FakeTransport.client([])

      assert :ok = Reply.backfill([view_thread(track, active)], client: {:ok, client})
      assert thread_of(track).reply_excerpt == "Already here"
      assert FakeTransport.calls(client) == []
    end

    test "one attempt per reply: a Fountain that cannot answer leaves it checked and empty" do
      track = insert_track(conversation_id: "unreachable")
      active = ~U[2026-09-28 17:00:00.000000Z]

      client =
        FakeTransport.client([
          {%{method: "GET", path: "/api/conversations/unreachable/events"}, {:error, :timeout}}
        ])

      assert :ok = Reply.backfill([view_thread(track, active)], client: {:ok, client})
      assert %{reply_excerpt: nil, reply_at: ^active} = thread_of(track)
      refute Reply.stale?(view_thread(track, active, reply_at: thread_of(track).reply_at))
    end
  end

  describe "the Inbox's read of excerpts" do
    test "costs the same queries for one track as for five" do
      owner = insert_user()
      project = insert_project(user: owner)
      stub(Fountain, :client, fn -> FakeTransport.client([], verify: false) end)

      cost = fn ->
        {{:ok, _tracks}, queries} = QueryCount.count(fn -> Tracks.list(owner, project.id) end)
        length(queries)
      end

      first = insert_track(project: project)
      keep_reply(first, "One reply")
      one = cost.()

      for n <- 1..4 do
        project |> then(&insert_track(project: &1)) |> keep_reply("Reply #{n}")
      end

      assert cost.() == one
    end

    test "never reaches another user's ids" do
      owner = insert_user()
      stranger = insert_user()
      project = insert_project(user: owner)
      track = insert_track(project: project, conversation_id: "private-conversation")
      stub(Fountain, :client, fn -> FakeTransport.client([], verify: false) end)
      {:ok, [view]} = Tracks.list(owner, project.id)
      active = DateTime.add(DateTime.utc_now(), -60)

      stale = %{
        view
        | threads:
            Enum.map(
              view.threads,
              &Map.merge(&1, %{reply_unread: true, status: :ready, last_active_at: active})
            )
      }

      assert Tracks.stale_replies?(owner, [stale])
      # The owner's listing, handed over with the stranger's session.
      assert :ok = Tracks.backfill_replies(stranger, [stale])
      assert thread_of(track).reply_at == nil

      # The owner's own session does reach it: Fountain has nothing, so the
      # reply is kept as checked and empty.
      assert :ok = Tracks.backfill_replies(owner, [stale])
      assert thread_of(track).reply_at == DateTime.truncate(active, :microsecond)
    end
  end
end
