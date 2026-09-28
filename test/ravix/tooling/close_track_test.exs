defmodule Ravix.Tooling.CloseTrackTest do
  use Ravix.DataCase, async: true
  use Mimic
  alias Ravix.Fountain.{FakeTransport, Shapes}
  alias Ravix.GitHub.Shapes, as: GitHubShapes
  alias Ravix.PromptQueue.Item
  alias Ravix.Tooling
  alias Ravix.Tooling.Receipt
  alias Ravix.Tracks
  alias Ravix.Tracks.Track
  import Ravix.ToolingFixture

  setup do
    owner = insert_user()
    creator = insert_user()
    project = insert_project(user: owner, repo_full_name: "acme/ledger", installation_id: 7)

    track =
      insert_track(
        project: project,
        slug: "kyoto",
        conversation_id: "c1",
        created_by: creator.id,
        created_by_login: creator.login
      )

    insert_track_member(track, creator)
    test = self()

    stub(Ravix.Previews.Lifecycle, :stop_service, fn track_id, :cleanup ->
      send(test, {:preview_stopped, track_id})
      :ok
    end)

    fountain([])
    conversations([{"c1", "idle"}])
    pull(%{"number" => 218, "state" => "closed", "merged_at" => "2026-09-27T00:00:00Z"})

    %{owner: owner, creator: creator, project: project, track: track}
  end

  defp fountain(expectations) do
    client = FakeTransport.client(expectations)
    stub(Ravix.Fountain, :client, fn -> client end)
    client
  end

  # The teardown of a shared track on conversation c1: its close turn, then
  # its conversation and every other thread's, ended.
  defp closing(threads \\ []) do
    fountain(
      [
        {%{method: "POST", path: "/api/conversations/c1/prompts"}, {202, [], %{}}},
        {%{method: "POST", path: "/api/conversations/c1/terminate"}, {200, [], %{}}}
      ] ++
        Enum.map(
          threads,
          &{%{method: "POST", path: "/api/conversations/#{&1}/terminate"}, {200, [], %{}}}
        )
    )
  end

  defp conversations(statuses) do
    stub(Ravix.MachineCache, :conversations, fn _client, _project, [fresh: true] ->
      {:ok,
       Enum.map(statuses, fn {id, status} ->
         Shapes.conversation(%{"id" => id, "status" => status})
       end)}
    end)
  end

  defp pull(raw) do
    stub(Ravix.Config, :github, fn -> Ravix.GitHubFake.app() end)

    stub(Ravix.GitHub, :pull_for_track, fn _app, 7, "acme/ledger", _branch, _track ->
      {:ok,
       raw &&
         GitHubShapes.pull_ref(
           Map.merge(%{"head" => %{"ref" => "branch"}, "updated_at" => "2026"}, raw)
         )}
    end)
  end

  defp close(user, track, args \\ %{}) do
    {p, _, _} = principal(user)
    close_as(p, track, args)
  end

  defp close_as(p, track, args) do
    Tooling.call(
      p,
      "close_track",
      Map.merge(%{"track_id" => track.id, "request_id" => "close-#{track.id}"}, args)
    )
  end

  defp closed?(track), do: Repo.get!(Track, track.id).closed_at != nil

  defp await_teardown do
    me = self()

    Ravix.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> me in Keyword.get(dictionary, :"$callers", [])
        nil -> false
      end
    end)
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000 end)
  end

  describe "who may close" do
    test "the project owner closes through the browser's durable path", c do
      closing()
      failed = insert_prompt(track: c.track, status: "failed")

      assert {:ok, %{closed: true, pr: %{number: 218, state: "merged"}}} = close(c.owner, c.track)
      await_teardown()

      assert closed?(c.track)
      assert Repo.get_by!(Item, id: failed.id).status == :cancelled
      track_id = c.track.id
      assert_received {:preview_stopped, ^track_id}
    end

    test "the creator closes their own track", c do
      closing()
      assert {:ok, %{closed: true}} = close(c.creator, c.track)
      await_teardown()
      assert closed?(c.track)
    end

    test "a private track's creator closes it", c do
      track = insert_track(project: c.project, visibility: :private, created_by: c.creator.id)
      assert {:ok, %{closed: true}} = close(c.creator, track)
      await_teardown()
      assert closed?(track)
    end

    test "a member without rights is forbidden; outsiders and non-invitees get not_found", c do
      member = insert_user()
      insert_project_member(c.project, member)
      guest = insert_user()
      insert_track_member(c.track, guest)

      for user <- [member, guest] do
        assert {:error, {:forbidden, _}} = close(user, c.track)
      end

      assert {:error, :not_found} = close(insert_user(), c.track)

      private = insert_track(project: c.project, visibility: :private, created_by: c.creator.id)

      # The project owner is not invited, so cannot see it; invited, still cannot close it.
      assert {:error, :not_found} = close(c.owner, private)
      assert {:error, :not_found} = close(member, private)
      insert_track_member(private, c.owner)
      assert {:error, {:forbidden, _}} = close(c.owner, private)

      refute closed?(c.track)
      refute closed?(private)
    end

    test "the tool needs tracks:write", c do
      {p, _, _} = principal(c.owner, "mcp", ["tracks:read"])
      assert {:error, _} = close_as(p, c.track, %{})
      refute closed?(c.track)
    end
  end

  describe "safety" do
    test "a running turn on any thread is refused without force", c do
      {:ok, _} =
        Tracks.Store.create_thread(%{
          track_id: c.track.id,
          title: "Next",
          conversation_id: "c2"
        })

      conversations([{"c1", "idle"}, {"c2", "running"}])
      closing(["c2"])

      assert {:error, {:conflict, "track_running", _}} = close(c.owner, c.track)
      refute closed?(c.track)

      assert {:ok, %{closed: true}} = close(c.owner, c.track, %{"force" => true})
      await_teardown()
      assert closed?(c.track)
    end

    test "queued prompts are refused without force, and force cancels them", c do
      closing()
      queued = insert_prompt(track: c.track)
      {p, _, _} = principal(c.owner)

      assert {:error, {:conflict, "prompts_queued", _}} = close_as(p, c.track, %{})
      refute closed?(c.track)

      # The refusal released its request_id: the same ID works once forced.
      assert {:ok, %{closed: true}} =
               close_as(p, c.track, %{"force" => true, "request_id" => "close-#{c.track.id}"})

      await_teardown()
      assert Repo.get_by!(Item, id: queued.id).status == :cancelled
    end

    test "a Fountain that cannot say whether a turn is running refuses without force", c do
      stub(Ravix.MachineCache, :conversations, fn _, _, _ -> {:error, :econnrefused} end)
      assert {:error, {:conflict, "status_unavailable", _}} = close(c.owner, c.track)
      refute closed?(c.track)
    end

    test "require_merged refuses an open, missing or unreadable pull request", c do
      pull(%{"number" => 9, "state" => "open"})

      assert {:error, {:conflict, "pr_not_merged", message}} =
               close(c.owner, c.track, %{"require_merged" => true})

      assert message =~ "open"

      pull(nil)

      assert {:error, {:conflict, "pr_not_merged", _}} =
               close(c.owner, c.track, %{"require_merged" => true})

      stub(Ravix.GitHub, :pull_for_track, fn _, _, _, _, _ -> {:error, :timeout} end)

      assert {:error, {:conflict, "pr_not_merged", _}} =
               close(c.owner, c.track, %{"require_merged" => true})

      refute closed?(c.track)
    end

    test "without require_merged an open pull request is reported, not refused", c do
      closing()
      pull(%{"number" => 9, "state" => "open"})
      assert {:ok, %{pr: %{number: 9, state: "open"}}} = close(c.owner, c.track)
      await_teardown()
    end

    test "a project without a repository reports no pull request", c do
      project = insert_project(user: c.owner, repo_full_name: nil)
      track = insert_track(project: project)
      reject(Ravix.GitHub, :pull_for_track, 5)
      assert {:ok, %{pr: %{number: nil, state: "none"}}} = close(c.owner, track)
      await_teardown()
    end

    test "a dedicated track's machine close is requested durably", c do
      track =
        insert_track(
          project: c.project,
          sandbox_layout: :dedicated,
          sandbox_id: "one",
          workdir: "/workspace/one"
        )

      assert {:ok, %{closed: true}} = close(c.owner, track)
      assert Repo.get!(Track, track.id).sandbox_stage == "closing"

      assert {:error, {:conflict, "track_closed", _}} =
               close(c.owner, track, %{"request_id" => "again"})
    end
  end

  describe "request_id" do
    test "a retry replays the receipt, even after the creator lost access", c do
      closing()
      {p, _, _} = principal(c.creator)
      assert {:ok, first} = close_as(p, c.track, %{})
      await_teardown()
      assert {:error, :not_found} = Ravix.Accounts.Access.track_access(c.creator, c.track.id)

      assert {:ok, replay} = close_as(p, c.track, %{})
      assert replay == Jason.decode!(Jason.encode!(first))

      assert {:error, :not_found} = close_as(p, c.track, %{"force" => true})
    end

    test "a refusal leaves no receipt behind", c do
      conversations([{"c1", "running"}])
      assert {:error, {:conflict, "track_running", _}} = close(c.owner, c.track)
      assert Repo.aggregate(Receipt, :count) == 0
    end
  end
end
