defmodule Ravix.Tracks.TitlingTest do
  use Ravix.DataCase, async: true

  import Mimic

  alias Ravix.Fountain.FakeTransport
  alias Ravix.Fountain.Shapes.Conversation
  alias Ravix.Hub
  alias Ravix.Hub.Event
  alias Ravix.Tracks
  alias Ravix.Tracks.{Store, Thread, Titling, Track}

  setup do
    owner = insert_user(login: "owner")
    project = insert_project(user: owner)

    track =
      insert_track(
        project: project,
        conversation_id: "c-#{System.unique_integer([:positive])}",
        slug: "crewe",
        title: "ravix/crewe",
        branch: "ravix/crewe"
      )

    client =
      FakeTransport.client(
        [
          {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
           {200, [], %{data: []}}}
        ],
        verify: false
      )

    stub(Ravix.Fountain, :client, fn -> client end)
    # The production path: titling under the TaskSupervisor, off the request.
    stub(Ravix.Config, :background_titling?, fn -> true end)
    :ok = Hub.subscribe(project.id)
    {:ok, owner: owner, project: project, track: track}
  end

  defp send_prompt(ctx, text, opts \\ []) do
    request_id = "req-#{System.unique_integer([:positive])}-abcdefghijklmnop"

    {:ok, _item} =
      Tracks.prompt(ctx.owner, ctx.track.id, %{
        "prompt" => text,
        "request_id" => request_id,
        "thread_id" => opts[:thread_id]
      })

    request_id
  end

  # Titling runs under the TaskSupervisor; its one visible effect is the
  # `:tracks` event it publishes after writing. The task is a `$callers`
  # child of the test, so it shares this test's sandbox and stubs.
  defp assert_titled(track_id) do
    assert_receive {:hub, %Event{name: :tracks, track_id: ^track_id}}, 2_000
  end

  defp thread(track), do: Store.thread(track.id)

  defp listed(id, title, source \\ "harness"),
    do: %Conversation{
      id: id,
      status: :idle,
      sandbox_id: nil,
      sprite_name: nil,
      inserted_at: nil,
      last_active_at: nil,
      turn_count: 1,
      model: nil,
      title: title,
      title_source: source
    }

  defp from_list(ctx, conversations),
    do: Titling.from_fountain(ctx.project.id, Titling.harness_titles(conversations))

  describe "the first prompt" do
    test "titles the default thread and its track, and says so on the hub", ctx do
      send_prompt(ctx, "Can you pull the latest main and fix the conflicts?")
      assert_titled(ctx.track.id)

      track = Repo.get!(Track, ctx.track.id)
      assert track.title == "Pull Latest Main"
      assert track.title_source == :auto
      # The label moves; the branch cut on the machine does not.
      assert track.branch == "ravix/crewe"
      assert track.slug == "crewe"

      assert %Thread{title: "Pull Latest Main", title_source: :auto} = thread(track)
    end

    test "a later prompt leaves the title alone", ctx do
      send_prompt(ctx, "pull latest main")
      assert_titled(ctx.track.id)

      request_id = send_prompt(ctx, "now deploy the staging environment")

      assert Titling.from_prompt(ctx.track.id, ctx.track.id, request_id, "deploy staging") ==
               :skipped

      refute_receive {:hub, %Event{name: :tracks}}, 100
      assert Repo.get!(Track, ctx.track.id).title == "Pull Latest Main"
    end

    test "a second thread is titled from its own first prompt, and the track keeps its name",
         ctx do
      send_prompt(ctx, "pull latest main")
      assert_titled(ctx.track.id)

      {:ok, second} =
        Store.create_thread(%{
          track_id: ctx.track.id,
          conversation_id: "c-second-#{System.unique_integer([:positive])}",
          title: "make the product much…"
        })

      send_prompt(ctx, "make the product much more simple and intuitive", thread_id: second.id)
      assert_titled(ctx.track.id)

      assert Repo.get!(Thread, second.id).title == "Make Product Simple and Intuitive"
      assert Repo.get!(Track, ctx.track.id).title == "Pull Latest Main"
    end

    test "a prompt with no words to title leaves the names as they were", ctx do
      request_id = send_prompt(ctx, "   please   ")
      assert Titling.from_prompt(ctx.track.id, ctx.track.id, request_id, "please") == :skipped
      assert Repo.get!(Track, ctx.track.id).title == "ravix/crewe"
    end
  end

  describe "a turn Ravix sent itself" do
    test "is passed over: the first prompt a person wrote titles the thread", ctx do
      send_prompt(ctx, "[ravix] Open this track. Make its working directory, then stop.")
      refute_receive {:hub, %Event{name: :tracks}}, 100
      assert Repo.get!(Track, ctx.track.id).title == "ravix/crewe"

      send_prompt(ctx, "Can you pull the latest main and fix the conflicts?")
      assert_titled(ctx.track.id)
      assert Repo.get!(Track, ctx.track.id).title == "Pull Latest Main"
      assert %Thread{title: "Pull Latest Main"} = thread(ctx.track)
    end
  end

  describe "titling after a caller's commit" do
    test "titles through the thread's door, for a member only", ctx do
      id = send_prompt(ctx, "Can you pull the latest main and fix the conflicts?")
      assert_titled(ctx.track.id)

      # Another user's ids are refused before anything is scheduled.
      stranger = insert_user()

      other =
        insert_track(conversation_id: "c-other", title: "ravix/other", branch: "ravix/other")

      assert {:error, _} =
               Tracks.title_after_prompt(stranger, ctx.track.id, ctx.track.id, id, "Anything")

      assert {:error, _} =
               Tracks.title_after_prompt(ctx.owner, other.id, other.id, id, "Fix the build")

      refute_receive {:hub, %Event{name: :tracks}}, 100
      assert Repo.get!(Track, other.id).title == "ravix/other"
    end
  end

  describe "a manual rename wins" do
    test "made before the first prompt: the track keeps it, the thread is still titled", ctx do
      :ok = Tracks.rename(ctx.owner, ctx.track.id, "Ledger cleanup")
      assert_titled(ctx.track.id)

      send_prompt(ctx, "pull latest main")
      assert_titled(ctx.track.id)

      track = Repo.get!(Track, ctx.track.id)
      assert {track.title, track.title_source} == {"Ledger cleanup", :manual}
      assert thread(track).title == "Pull Latest Main"
    end

    test "made while the title is being worked out: the rename is not overwritten", ctx do
      test = self()

      # Hold the titling task between its read and its write.
      stub(Ravix.Tracks.Title, :from_prompt, fn prompt ->
        send(test, {:titling, self()})

        receive do
          :go -> call_original(Ravix.Tracks.Title, :from_prompt, [prompt])
        end
      end)

      send_prompt(ctx, "pull latest main")
      assert_receive {:titling, task}, 2_000
      ref = Process.monitor(task)

      :ok = Tracks.rename(ctx.owner, ctx.track.id, "Ledger cleanup")
      assert_titled(ctx.track.id)

      send(task, :go)
      assert_receive {:DOWN, ^ref, :process, ^task, :normal}, 2_000

      track = Repo.get!(Track, ctx.track.id)
      assert {track.title, track.title_source} == {"Ledger cleanup", :manual}
    end

    test "made by a release that does not record who named it", ctx do
      # An older release renames without writing `title_source`; the title
      # no longer matching the branch is what shows a person chose it.
      Repo.update_all(from(t in Track, where: t.id == ^ctx.track.id), set: [title: "Old name"])

      send_prompt(ctx, "pull latest main")
      assert_titled(ctx.track.id)

      assert Repo.get!(Track, ctx.track.id).title == "Old name"
    end

    test "and a stale read writes nothing", ctx do
      track = Repo.get!(Track, ctx.track.id)
      read = thread(track)
      Repo.update_all(from(t in Thread, where: t.id == ^read.id), set: [title: "Moved"])

      assert Store.auto_title(read, track, "Pull Latest Main") == :stale
      assert Repo.get!(Track, track.id).title == "ravix/crewe"
      assert thread(track).title == "Moved"
    end
  end

  describe "a harness title saved by Fountain" do
    setup ctx do
      send_prompt(ctx, "pull latest main")
      assert_titled(ctx.track.id)
      :ok
    end

    test "replaces the prompt's title on thread and track", ctx do
      assert [:ok] = from_list(ctx, [listed(ctx.track.conversation_id, "Main branch pull")])

      assert_titled(ctx.track.id)
      assert Repo.get!(Track, ctx.track.id).title == "Main branch pull"
      assert thread(ctx.track).title == "Main branch pull"
      assert thread(ctx.track).title_source == :auto
    end

    test "is tidied, and skipped without a write when the thread already has it", ctx do
      assert [:ok] =
               from_list(ctx, [listed(ctx.track.conversation_id, "  \"Main branch pull\" ")])

      assert_titled(ctx.track.id)

      assert [:skipped] = from_list(ctx, [listed(ctx.track.conversation_id, "Main branch pull")])
      refute_receive {:hub, %Event{name: :tracks}}, 50
    end

    test "never replaces a person's rename of the track", ctx do
      :ok = Tracks.rename(ctx.owner, ctx.track.id, "Ledger cleanup")

      assert [:ok] = from_list(ctx, [listed(ctx.track.conversation_id, "Main branch pull")])

      assert Repo.get!(Track, ctx.track.id).title == "Ledger cleanup"
      assert thread(ctx.track).title == "Main branch pull"
    end

    test "never replaces a person's rename of the thread", ctx do
      :ok = Tracks.rename_thread(ctx.owner, ctx.track.id, ctx.track.id, "Mine")

      assert [] = from_list(ctx, [listed(ctx.track.conversation_id, "Main branch pull")])
      assert thread(ctx.track).title == "Mine"
      assert thread(ctx.track).title_source == :manual
    end

    test "adopts only titles Fountain marks as the harness's", ctx do
      id = ctx.track.conversation_id

      assert Titling.harness_titles([
               listed("a", "Set by the owner", "user"),
               listed("b", "   "),
               listed("c", nil),
               listed("d", "No source", nil),
               listed(nil, "No id")
             ]) == %{}

      # Before RAV-107 Ravix opened every conversation with a title, which
      # Fountain locked as the owner's. Unsourced, it is that stale name.
      assert [] = from_list(ctx, [listed(id, "New thread", nil)])
      assert thread(ctx.track).title == "Pull Latest Main"

      assert [:ok] = from_list(ctx, [listed(id, "Main branch pull", "harness")])
      assert thread(ctx.track).title == "Main branch pull"
    end

    test "is scoped to the project, and ignores unknown conversations", ctx do
      other_project = insert_project(user: ctx.owner)

      assert [] =
               Titling.from_fountain(
                 other_project.id,
                 Titling.harness_titles([listed(ctx.track.conversation_id, "Elsewhere")])
               )

      assert [] = from_list(ctx, [listed("c-unknown", "Anything")])
      assert thread(ctx.track).title == "Pull Latest Main"
    end

    test "after_list/2 adopts in the background and reads nothing for an untitled list", ctx do
      :ok = Titling.after_list(ctx.project.id, [listed(ctx.track.conversation_id, nil)])
      refute_receive {:hub, %Event{name: :tracks}}, 50

      :ok =
        Titling.after_list(ctx.project.id, [listed(ctx.track.conversation_id, "Main branch pull")])

      assert_titled(ctx.track.id)
      assert Repo.get!(Track, ctx.track.id).title == "Main branch pull"
    end
  end
end
