defmodule Ravix.CommentsTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Comments
  alias Ravix.Comments.Store
  alias Ravix.Fountain.Client
  alias Ravix.Hub
  alias Ravix.Hub.Event
  alias Ravix.PromptQueue
  alias Ravix.Tracks

  setup do
    owner = insert_user(login: "owner-#{System.unique_integer([:positive])}")
    member = insert_user()
    guest = insert_user()
    stranger = insert_user()
    project = insert_project(user: owner)
    insert_project_member(project, member)
    track = insert_track(project: project, conversation_id: "c-#{System.unique_integer()}")
    insert_track_member(track, guest)

    %{
      owner: owner,
      member: member,
      guest: guest,
      stranger: stranger,
      project: project,
      track: track
    }
  end

  describe "post/5, edit/4 and delete/3" do
    test "the author posts, edits and deletes; the anchor and a bounded body are kept", c do
      Hub.subscribe(c.project.id)

      assert {:ok, comment} =
               Comments.post(c.member, c.track.id, nil, "  Looks good  ", %{
                 anchor_turn_id: "turn-2",
                 anchor_event_id: 41
               })

      assert comment.body == "Looks good"
      assert comment.thread_id == c.track.id
      assert comment.anchor_turn_id == "turn-2"
      assert comment.anchor_event_id == 41
      assert comment.conversation_id == c.track.conversation_id
      assert comment.author.login == c.member.login
      member_id = c.member.id
      track_id = c.track.id
      assert_receive {:hub, %Event{name: :comment, track_id: ^track_id, user_id: ^member_id}}

      assert {:ok, edited} = Comments.edit(c.member, c.track.id, comment.id, "Looks great")
      assert edited.body == "Looks great"
      assert edited.edited_at

      assert {:ok, deleted} = Comments.delete(c.member, c.track.id, comment.id)
      assert deleted.deleted_at
      assert deleted.body == nil

      # A deleted comment keeps its place and loses its body, and is final.
      assert {:ok, [listed]} = Comments.list(c.owner, c.track.id, nil)
      assert listed.id == comment.id and listed.body == nil
      assert {:error, :not_found} = Comments.edit(c.member, c.track.id, comment.id, "back")
      assert {:error, :not_found} = Comments.delete(c.member, c.track.id, comment.id)
    end

    test "somebody else's comment is refused, even to the project's owner", c do
      {:ok, comment} = Comments.post(c.member, c.track.id, nil, "Mine")

      for user <- [c.owner, c.guest] do
        assert {:error, {:forbidden, _}} = Comments.edit(user, c.track.id, comment.id, "Theirs")
        assert {:error, {:forbidden, _}} = Comments.delete(user, c.track.id, comment.id)
      end

      assert Store.get(comment.id).body == "Mine"
      assert is_nil(Store.get(comment.id).deleted_at)
    end

    test "empty, oversized and badly anchored input", c do
      assert {:error, %Ecto.Changeset{}} = Comments.post(c.member, c.track.id, nil, "   ")

      long = String.duplicate("a", Comments.Comment.max_body() + 1)
      assert {:error, %Ecto.Changeset{} = cs} = Comments.post(c.member, c.track.id, nil, long)
      assert "Keep comments under 10,000 characters." in errors_on(cs).body

      limit = String.duplicate("a", Comments.Comment.max_body())

      assert {:ok, comment} =
               Comments.post(c.member, c.track.id, nil, limit, %{
                 anchor_turn_id: String.duplicate("t", 201),
                 anchor_event_id: -1
               })

      assert is_nil(comment.anchor_turn_id) and is_nil(comment.anchor_event_id)
      assert {:error, %Ecto.Changeset{}} = Comments.edit(c.member, c.track.id, comment.id, long)
    end

    test "strangers, closed tracks and other tracks' ids get not_found", c do
      {:ok, comment} = Comments.post(c.member, c.track.id, nil, "Here")
      other = insert_track(project: c.project)

      assert {:error, :not_found} = Comments.post(c.stranger, c.track.id, nil, "Hi")
      assert {:error, :not_found} = Comments.list(c.stranger, c.track.id, nil)
      assert {:error, :not_found} = Comments.edit(c.stranger, c.track.id, comment.id, "x")
      assert {:error, :not_found} = Comments.delete(c.member, other.id, comment.id)
      assert {:error, :not_found} = Comments.list(c.member, c.track.id, other.id)
      assert {:error, :not_found} = Comments.mentionable(c.stranger, c.track.id)

      # A removed member loses the thread with the membership.
      Ravix.Repo.delete_all(Ravix.Projects.ProjectMember)
      assert {:error, :not_found} = Comments.list(c.member, c.track.id, nil)
      assert {:error, :not_found} = Comments.edit(c.member, c.track.id, comment.id, "x")
      assert {:ok, [_]} = Comments.list(c.guest, c.track.id, nil)
    end

    test "a private track's outsiders can neither read nor post", c do
      creator = insert_user()
      insert_project_member(c.project, creator)

      private =
        insert_track(
          project: c.project,
          visibility: :private,
          created_by: creator.id,
          created_by_login: creator.login
        )

      assert {:ok, _} = Comments.post(creator, private.id, nil, "Just us")
      assert {:error, :not_found} = Comments.list(c.member, private.id, nil)
      assert {:error, :not_found} = Comments.post(c.member, private.id, nil, "Me too")
      assert {:error, :not_found} = Comments.list(c.owner, private.id, nil)
    end
  end

  describe "never to the agent" do
    test "a comment makes no Fountain request and queues no prompt", c do
      reject(&Ravix.Fountain.client/0)
      reject(&PromptQueue.Store.enqueue/5)
      reject(&PromptQueue.Store.enqueue/6)
      reject(&Tracks.prompt/3)

      {:ok, comment} = Comments.post(c.member, c.track.id, nil, "@#{c.owner.login} please look")
      {:ok, _} = Comments.edit(c.member, c.track.id, comment.id, "Please look")
      {:ok, _} = Comments.delete(c.member, c.track.id, comment.id)

      assert PromptQueue.Store.summaries(c.track.id) == []
    end

    test "MCP read_track pages Fountain's events and never the comments", c do
      {:ok, _} = Comments.post(c.owner, c.track.id, nil, "secret human note")
      {p, _, _} = Ravix.ToolingFixture.principal(c.owner)
      stub(Ravix.Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)

      stub(Ravix.Fountain, :events_page, fn _, _, _ ->
        {:ok,
         %{
           events: [%{"id" => 1, "kind" => "output", "data" => "hi"}],
           next_cursor: nil,
           has_more: false
         }}
      end)

      assert {:ok, page} = Ravix.Tooling.call(p, "read_track", %{"track_id" => c.track.id})
      refute inspect(page) =~ "secret human note"
      refute Enum.any?(page.events, &(&1["kind"] == "comment"))
    end
  end

  describe "mentions" do
    test "parsing takes GitHub logins and leaves emails, paths and code alone" do
      assert Comments.mentions("@Alice and @bob-2, again @alice.") == ["alice", "bob-2"]
      assert Comments.mentions("mail me@x.com, see a/@b or `@c`") == []
      assert length(Comments.mentions(Enum.map_join(1..30, " ", &"@u#{&1}"))) == 20
    end

    test "only people who can reach the track are notified, never the author", c do
      private_outsider = insert_user()
      insert_project(user: private_outsider)

      body =
        "@#{c.owner.login} @#{c.guest.login} @#{c.stranger.login} @#{c.member.login} @nobody"

      {:ok, comment} = Comments.post(c.member, c.track.id, nil, body)

      assert Enum.sort(Store.mentioned(comment.id)) == Enum.sort([c.owner.id, c.guest.id])

      # An edit notifies newly named people and keeps the first mention.
      insert_track_member(c.track, private_outsider)
      {:ok, _} = Comments.edit(c.member, c.track.id, comment.id, "@#{private_outsider.login}")

      assert Enum.sort(Store.mentioned(comment.id)) ==
               Enum.sort([c.owner.id, c.guest.id, private_outsider.id])
    end

    test "the mentionable list honors private tracks and leaves out the caller", c do
      assert {:ok, people} = Comments.mentionable(c.member, c.track.id)
      assert Enum.sort(Enum.map(people, & &1.login)) == Enum.sort([c.owner.login, c.guest.login])

      creator = insert_user()
      insert_project_member(c.project, creator)
      invited = insert_user()

      private =
        insert_track(
          project: c.project,
          visibility: :private,
          created_by: creator.id,
          created_by_login: creator.login
        )

      insert_track_member(private, invited)
      assert {:ok, people} = Comments.mentionable(creator, private.id)
      assert Enum.map(people, & &1.login) == [invited.login]

      {:ok, comment} =
        Comments.post(creator, private.id, nil, "@#{c.owner.login} @#{invited.login}")

      assert Store.mentioned(comment.id) == [invited.id]
    end
  end

  describe "unread and the Inbox" do
    setup do
      stub(Ravix.Fountain, :client, fn -> Client.new("https://fountain.test", "key") end)
      stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:ok, []} end)
      :ok
    end

    test "a comment marks the thread unread for everyone but its author", c do
      for user <- [c.owner, c.member, c.guest], do: Tracks.mark_read(user, c.track.id)
      {:ok, _} = Comments.post(c.member, c.track.id, nil, "New note")

      assert thread(c.owner, c).unread
      assert thread(c.guest, c).unread
      refute thread(c.member, c).unread
      # A comment naming nobody is not a reply and not a mention.
      refute thread(c.owner, c).reply_unread
      assert is_nil(thread(c.owner, c).mention)

      Tracks.mark_read(c.owner, c.track.id)
      refute thread(c.owner, c).unread
    end

    test "a mention reaches the named person's Inbox until they read the thread", c do
      Tracks.mark_read(c.owner, c.track.id)
      {:ok, comment} = Comments.post(c.member, c.track.id, nil, "@#{c.owner.login} over to you")

      assert {:ok, [view]} = Tracks.list(c.owner, c.project.id)
      assert view.mention.comment_id == comment.id
      assert view.mention.author_login == c.member.login
      assert hd(view.threads).mention.comment_id == comment.id
      assert {:ok, [other]} = Tracks.list(c.guest, c.project.id)
      assert is_nil(other.mention)

      Tracks.mark_read(c.owner, c.track.id)
      assert {:ok, [read]} = Tracks.list(c.owner, c.project.id)
      assert is_nil(read.mention)

      # A deleted comment's mention goes with it.
      {:ok, again} = Comments.post(c.member, c.track.id, nil, "@#{c.owner.login} again")
      {:ok, _} = Comments.delete(c.member, c.track.id, again.id)
      assert {:ok, [gone]} = Tracks.list(c.owner, c.project.id)
      assert is_nil(gone.mention)
      refute gone.unread
    end
  end

  defp thread(user, c) do
    {:ok, threads} = Tracks.threads(user, c.track.id)
    Enum.find(threads, &(&1.id == c.track.id))
  end
end
