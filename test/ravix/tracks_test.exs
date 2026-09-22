defmodule Ravix.TracksTest do
  use Ravix.DataCase, async: true

  import Mimic

  alias Ravix.Fountain.{Client, Error, FakeTransport}
  alias Ravix.Fountain.Shapes
  alias Ravix.Hub
  alias Ravix.Hub.Event
  alias Ravix.PromptQueue.Body
  alias Ravix.QueryCount
  alias Ravix.Tracks
  alias Ravix.Tracks.{Diff, Files, Names, Origin, Track}
  alias Ravix.Tracks.Transcript.{Block, Turn}

  @root "/home/sprite/work/kyoto"

  setup_all do
    Ravix.TracksBoot.ensure_running()
    :ok
  end

  # ── the pure parts ─────────────────────────────────────────────────────

  describe "confine/2" do
    test "the file panel cannot read outside its own track" do
      # `GET /api/sandboxes/:id/file` will serve anything on the box, including
      # another track's work and `/home/sprite/.ssh`. This is what stops it.
      assert Tracks.confine(@root, nil) == @root
      assert Tracks.confine(@root, "src/app.ts") == "#{@root}/src/app.ts"
      assert Tracks.confine(@root, "../other/secret") == @root
      assert Tracks.confine(@root, "/home/sprite/.ssh/id_ed25519") == @root
      assert Tracks.confine(@root, "/home/sprite/work/kyoto-2/x") == @root
      assert Tracks.confine(@root, "#{@root}/deep/./file") == "#{@root}/deep/file"
    end
  end

  describe "summarize_diff/1" do
    test "a diff is counted per file, without the headers" do
      diff =
        Enum.join(
          [
            "diff --git a/src/app.ts b/src/app.ts",
            "index 111..222 100644",
            "--- a/src/app.ts",
            "+++ b/src/app.ts",
            "@@ -1,3 +1,4 @@",
            " context",
            "+added one",
            "+added two",
            "-removed one",
            "diff --git a/new.txt b/new.txt",
            "new file mode 100644",
            "--- /dev/null",
            "+++ b/new.txt",
            "@@ -0,0 +1,1 @@",
            "+hello"
          ],
          "\n"
        )

      assert Tracks.summarize_diff(diff) == [
               # `+++` and `---` are file headers rather than content; counting
               # them puts a phantom line on every changed file.
               %Diff.Change{path: "src/app.ts", added: 2, removed: 1, status: :modified},
               %Diff.Change{path: "new.txt", added: 1, removed: 0, status: :added}
             ]
    end

    test "a deletion and a rename are told apart" do
      deleted =
        "diff --git a/gone.ts b/gone.ts\ndeleted file mode 100644\n--- a/gone.ts\n+++ /dev/null\n@@ -1 +0,0 @@\n-x"

      assert [%Diff.Change{path: "gone.ts", added: 0, removed: 1, status: :deleted}] =
               Tracks.summarize_diff(deleted)

      renamed =
        "diff --git a/old.ts b/new.ts\nsimilarity index 100%\nrename from old.ts\nrename to new.ts"

      assert [%Diff.Change{path: "new.ts", status: :renamed}] = Tracks.summarize_diff(renamed)
    end

    test "an empty diff is an empty list, not a phantom file" do
      assert Tracks.summarize_diff("") == []
      assert Tracks.summarize_diff("\n\n") == []
    end
  end

  describe "present/2" do
    setup do
      project = insert_project(rev: 3)

      {:ok,
       project: project,
       track: insert_track(project: project, rev: 3, opened_at: DateTime.utc_now())}
    end

    test "status comes from the row and the live conversation", %{project: project, track: track} do
      assert %{status: :ready} = Tracks.present(track, project: project)

      assert %{status: :running} =
               Tracks.present(track,
                 project: project,
                 live: conversation(%{"status" => "running"})
               )

      assert %{status: :failed} =
               Tracks.present(track,
                 project: project,
                 live: conversation(%{"status" => "failed"})
               )

      assert %{status: :opening} = Tracks.present(%{track | opened_at: nil}, project: project)
      closed = %{track | closed_at: DateTime.utc_now()}

      assert %{status: :closed} =
               Tracks.present(closed,
                 project: project,
                 live: conversation(%{"status" => "running"})
               )
    end

    test "stale is a comparison of revisions, not a flag", %{project: project, track: track} do
      refute Tracks.present(track, project: project).stale
      assert Tracks.present(%{track | rev: 2}, project: project).stale
    end

    test "unread follows the machine's last word against this person's last look", %{
      project: project,
      track: track
    } do
      refute Tracks.present(track, project: project).unread
      live = conversation(%{"last_active_at" => "2026-09-09T10:00:00Z", "turn_count" => 4})
      presented = Tracks.present(track, project: project, live: live)
      assert presented.unread
      assert presented.turn_count == 4
      assert presented.last_active_at == ~U[2026-09-09 10:00:00Z]

      refute Tracks.present(track,
               project: project,
               live: live,
               last_read: ~U[2026-09-09 10:00:01Z]
             ).unread

      assert Tracks.present(track,
               project: project,
               live: live,
               last_read: ~U[2026-09-09 09:59:59Z]
             ).unread
    end

    test "the origin is typed", %{project: project, track: track} do
      pr = %{
        track
        | origin_kind: :pr,
          origin_number: 12,
          origin_title: "Fix",
          origin_url: "https://github.com/x/y/pull/12"
      }

      assert %{
               origin: %{
                 kind: :pr,
                 number: 12,
                 title: "Fix",
                 url: "https://github.com/x/y/pull/12"
               }
             } = Tracks.present(pr, project: project)

      # There is nothing left to coerce here: the column is one of the
      # startable kinds, and a row carrying anything else cannot be written. See
      # `Ravix.SchemasTest` for the refusal and `open/4` for the boundary
      # where a browser's word becomes one of them.
      assert Tracks.Track.origin_kinds() == [:blank, :branch, :pr, :issue, :plan]
    end

    test "a plan track loads and presents, and plan is now a kind that starts",
         %{project: project, track: track} do
      # The release before this one could read plan tracks without starting
      # them (expand); this one starts them (contract). The database word
      # still loads, and the row presents with its kind rather than raising.
      type = Tracks.Track.__schema__(:type, :origin_kind)
      assert Ecto.Type.load(type, "plan") == {:ok, :plan}

      plan = %{track | origin_kind: :plan, origin_title: "Ship the API"}

      assert %{origin: %{kind: :plan, title: "Ship the API"}} =
               Tracks.present(plan, project: project)

      # Startable now, and read-only kinds are empty again: the enum is
      # exactly the startable kinds, with nothing loaded that cannot start.
      assert :plan in Tracks.Track.origin_kinds()
      assert Ecto.Enum.values(Tracks.Track, :origin_kind) == Tracks.Track.origin_kinds()
    end
  end

  # ── the rows, and who may see them ─────────────────────────────────────

  # `present/2` reads a conversation, not the JSON one arrived as. Built here
  # by the boundary that really builds it, so this cannot claim a shape
  # `Ravix.Fountain` does not answer with.
  defp conversation(raw), do: Shapes.conversation(raw)

  defp quiet_fountain(project, conversations \\ []) do
    client =
      FakeTransport.client(
        [
          {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
           {200, [], %{data: conversations}}}
        ],
        verify: false
      )

    stub(Ravix.Fountain, :client, fn -> client end)
    client
  end

  describe "list/2" do
    setup do
      owner = insert_user()
      project = insert_project(user: owner)
      a = insert_track(project: project, slug: "a", conversation_id: "c-a")
      b = insert_track(project: project, slug: "b", conversation_id: "c-b")
      _closed = insert_track(project: project, slug: "z", closed_at: DateTime.utc_now())
      {:ok, owner: owner, project: project, a: a, b: b}
    end

    test "the owner sees every open track, with live status", ctx do
      quiet_fountain(ctx.project, [
        %{
          id: "c-a",
          status: "running",
          last_active_at: "2026-09-09T10:00:00Z",
          turn_count: 2,
          inserted_at: "x"
        }
      ])

      assert {:ok, [a, b]} = Tracks.list(ctx.owner, ctx.project.id)
      assert a.slug == "a" and a.status == :running and a.role == :owner and a.unread
      assert b.slug == "b" and b.status == :opening and b.turn_count == 0
      assert [%{login: owner_login}] = a.people
      assert owner_login == ctx.owner.login
    end

    test "a project member sees every track as a member", ctx do
      quiet_fountain(ctx.project)
      member = insert_user()
      insert_project_member(ctx.project, member)
      assert {:ok, [%{role: :member}, %{role: :member}]} = Tracks.list(member, ctx.project.id)
    end

    test "somebody invited to one track sees that one and is not told about the others", ctx do
      quiet_fountain(ctx.project)
      guest = insert_user()
      insert_track_member(ctx.b, guest)
      assert {:ok, [%{slug: "b", role: :member}]} = Tracks.list(guest, ctx.project.id)
    end

    test "a stranger, and a member of nothing here, get not found", ctx do
      quiet_fountain(ctx.project)
      assert {:error, :not_found} = Tracks.list(insert_user(), ctx.project.id)
      assert {:error, :not_found} = Tracks.list(ctx.owner, Ecto.UUID.generate())
    end

    test "the sidebar costs the same whether a project has two tracks or twenty", ctx do
      quiet_fountain(ctx.project)
      assert {:ok, [_, _]} = Tracks.list(ctx.owner, ctx.project.id)
      small = QueryCount.queries(fn -> Tracks.list(ctx.owner, ctx.project.id) end)

      for i <- 3..20, do: insert_track(project: ctx.project, slug: "t#{i}")
      insert_project_member(ctx.project, insert_user())
      insert_track_member(ctx.a, insert_user())

      {result, queries} = QueryCount.count(fn -> Tracks.list(ctx.owner, ctx.project.id) end)
      assert {:ok, listed} = result
      assert length(listed) == 20

      # Was four per track -- the same project members and the same owner,
      # read again for every row -- so twenty tracks cost eighty-three
      # queries. The count is now flat, and this is the assertion that says
      # so: no assertion on the returned list can see the difference.
      assert length(queries) == small
      assert Enum.count(queries, &(&1 == "project_members")) == 1
      assert Enum.count(queries, &(&1 == "users")) == 1
      assert Enum.count(queries, &(&1 == "track_members")) == 1
      assert Enum.count(queries, &(&1 == "track_invites")) == 1
    end

    test "a Fountain that cannot be reached still lists the rows", ctx do
      client =
        FakeTransport.client(
          [{%{method: "GET", path: "/api/conversations"}, {:error, :econnrefused}}],
          verify: false
        )

      stub(Ravix.Fountain, :client, fn -> client end)
      assert {:ok, [%{status: :opening}, _]} = Tracks.list(ctx.owner, ctx.project.id)
    end
  end

  describe "get/2" do
    test "the track, its ribbon and the starters", _ctx do
      owner = insert_user()
      project = insert_project(user: owner, repo_full_name: "acme/ledger")

      track =
        insert_track(
          project: project,
          slug: "kyoto",
          origin_kind: "branch",
          origin_base: "main",
          branch: "ana/kyoto"
        )

      client =
        FakeTransport.client(
          [
            {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}},
            {%{method: "GET", path: "/api/environments/#{project.environment_id}"},
             {200, [], %{data: %{setup_script: "npm ci\n"}}}}
          ],
          verify: false
        )

      stub(Ravix.Fountain, :client, fn -> client end)

      assert {:ok, %{track: presented, header: header, starters: starters}} =
               Tracks.get(owner, track.id)

      assert presented.id == track.id

      assert header == %Ravix.Tracks.Header{
               copy_of: "ledger",
               branched_from: %{branch: "ana/kyoto", base: "main"},
               created: %{dir: "kyoto", files: nil},
               has_setup_script: true
             }

      # This is still the only reader of `branched_from`, `created` and
      # `has_setup_script`; the ribbon renders `copy_of` alone. See
      # `Ravix.Tracks.Header`.
      assert [%Ravix.Spec.Starter{label: _, prompt: _} | _] = starters
      assert {:error, :not_found} = Tracks.get(insert_user(), track.id)
    end

    test "a page opening may take the memo's conversations; a refresh may not" do
      owner = insert_user()
      project = insert_project(user: owner)
      track = insert_track(project: project)

      client =
        FakeTransport.client(
          [
            {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}},
            {%{method: "GET", path: "/api/environments/#{project.environment_id}"},
             {200, [], %{data: %{}}}},
            {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}}
          ],
          verify: false
        )

      stub(Ravix.Fountain, :client, fn -> client end)

      # The first read has nothing memoised and must list them either way.
      assert {:ok, _} = Tracks.get(owner, track.id, fresh: false)

      # The second is what a track page's first paint does, and is the round
      # trip it no longer waits through: the memo is still inside
      # `MachineCache.ttl_ms/0`, so nothing is asked of Fountain.
      assert {:ok, _} = Tracks.get(owner, track.id, fresh: false)
      assert listings(client) == 1

      # A refresh runs because the hub said one of these four things changed,
      # so the memo it would read is the answer it already knows is stale.
      assert {:ok, _} = Tracks.get(owner, track.id, fresh: true)
      assert listings(client) == 2

      # And the default is the careful one.
      assert {:ok, _} = Tracks.get(owner, track.id)
      assert listings(client) == 3
    end
  end

  defp listings(client) do
    client
    |> FakeTransport.calls()
    |> Enum.count(&(&1.method == "GET" and &1.path == "/api/conversations"))
  end

  # ── opening ────────────────────────────────────────────────────────────

  describe "open/4" do
    setup do
      owner = insert_user(login: "Ana")

      project =
        insert_project(user: owner, repo_full_name: "acme/ledger", default_branch: "main", rev: 2)

      stub(Ravix.Projects, :prepare_machine, fn _project, _client -> :ok end)
      Hub.subscribe(project.id)
      {:ok, owner: owner, project: project}
    end

    # A Fountain with (or without) a machine, that accepts one conversation
    # and, on an attach, one prompt.
    defp opening_fountain(project, machine?) do
      conversations =
        if machine?,
          do: [
            %{
              id: "c-old",
              sandbox_id: "sb-1",
              status: "idle",
              inserted_at: "2026-09-01T00:00:00Z"
            }
          ],
          else: []

      client =
        FakeTransport.client(
          [
            {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
             {200, [], %{data: conversations}}},
            {%{method: "POST", path: "/api/conversations"}, {201, [], %{data: %{id: "c-new"}}}}
          ] ++
            if(machine?,
              do: [
                {%{method: "POST", path: "/api/conversations/c-new/prompts"},
                 {202, [], %{data: %{}}}}
              ],
              else: []
            )
        )

      stub(Ravix.Fountain, :client, fn -> client end)
      client
    end

    test "attaching to the machine that is there: the opening turn is a separate prompt", ctx do
      client = opening_fountain(ctx.project, true)

      assert {:ok, presented} =
               Tracks.open(ctx.owner, ctx.project.id, %{"title" => "Kyoto"}, opening_turn: :sync)

      assert presented.slug == "kyoto"
      assert presented.title == "ravix/Kyoto"
      assert presented.branch == "ravix/Kyoto"
      assert presented.workdir == "/home/sprite/work/kyoto"
      assert presented.conversation_id == "c-new"
      assert presented.role == :owner

      assert presented.origin ==
               %Origin{kind: :blank, base: "main", number: nil, title: nil, url: nil}

      [_list, create, prompt] = FakeTransport.calls(client)
      assert create.body["sandbox_id"] == "sb-1"
      assert create.body["channel_id"] == "ravix:#{ctx.project.id}:kyoto@r2"
      assert create.body["fresh"] == true
      assert create.body["agent_id"] == ctx.project.agent_id
      assert create.body["environment_id"] == ctx.project.environment_id
      assert create.body["vault_id"] == ctx.project.vault_id
      refute Map.has_key?(create.body, "prompt")
      assert prompt.body["prompt"] =~ "[ravix] Open this track"

      assert prompt.body["prompt"] =~
               "git worktree add /home/sprite/work/kyoto -b ravix/Kyoto origin/main"

      row = Repo.get!(Track, presented.id)
      assert row.opened_at
      assert row.rev == 2
      assert row.created_by_login == "Ana"
      project_id = ctx.project.id
      track_id = presented.id
      assert_receive {:hub, %Event{name: :turn, track_id: ^track_id}}
      # Named with the track it opened, so a page showing a sibling track of
      # the same project can leave it alone.
      assert_receive {:hub, %Event{name: :tracks, project_id: ^project_id, track_id: ^track_id}}
    end

    test "provisioning: the opening turn rides along with the launch", ctx do
      client = opening_fountain(ctx.project, false)
      assert {:ok, presented} = Tracks.open(ctx.owner, ctx.project.id, %{title: "Kyoto"})

      [_list, create] = FakeTransport.calls(client)
      assert create.body["sandbox_mode"] == "persistent"
      refute Map.has_key?(create.body, "sandbox_id")
      assert create.body["prompt"] =~ "[ravix] Open this track"
      assert Repo.get!(Track, presented.id).opened_at
    end

    test "a name in use gets a suffix rather than a refusal, and a closed name is free", ctx do
      insert_track(project: ctx.project, slug: "kyoto")
      insert_track(project: ctx.project, slug: "kyoto-2", closed_at: DateTime.utc_now())
      opening_fountain(ctx.project, false)

      # The slugs in use were read with the names, so a popular name costs no
      # query per candidate: the project, every track once, the insert, and
      # the row marked opened.
      {result, queries} =
        QueryCount.count(fn -> Tracks.open(ctx.owner, ctx.project.id, %{title: "Kyoto"}) end)

      assert {:ok, %{slug: "kyoto-2"}} = result
      assert queries == ["projects", "tracks", "tracks", "tracks"]
    end

    # The one refusal `plan/4` cannot rule out: somebody opening a track with
    # the same name between the read and the insert. Reproduced at the exact
    # moment -- while Fountain is making the conversation -- so the partial
    # unique index on open slugs is what refuses, as it would in production.
    defp race_for_the_slug(project) do
      expect(Ravix.Fountain, :create_conversation, fn client, launch ->
        insert_track(project: project, slug: "kyoto")
        Mimic.call_original(Ravix.Fountain, :create_conversation, [client, launch])
      end)
    end

    test "a row that will not insert ends the conversation it was cut for", ctx do
      client = opening_fountain(ctx.project, false)

      FakeTransport.expect(
        client,
        %{method: "POST", path: "/api/conversations/c-new/terminate"},
        {200, [], %{}}
      )

      race_for_the_slug(ctx.project)

      assert {:error, {:conflict, "slug_taken", message}} =
               Tracks.open(ctx.owner, ctx.project.id, %{title: "Kyoto"})

      assert message =~ "that name"

      [_list, create, terminate] = FakeTransport.calls(client)
      assert create.path == "/api/conversations"
      assert terminate.path == "/api/conversations/c-new/terminate"

      # Only the winner's row exists, and nobody was told a track opened.
      assert [%Track{slug: "kyoto", conversation_id: nil}] =
               Tracks.Store.tracks_of(ctx.project.id)

      refute_received {:hub, %Event{name: :tracks}}
    end

    test "a concurrent branch reservation unwinds the losing conversation", ctx do
      client = opening_fountain(ctx.project, false)

      FakeTransport.expect(
        client,
        %{method: "POST", path: "/api/conversations/c-new/terminate"},
        {200, [], %{}}
      )

      expect(Ravix.Fountain, :create_conversation, fn client, launch ->
        insert_track(project: ctx.project, slug: "other-dir", branch: "ravix/race")
        Mimic.call_original(Ravix.Fountain, :create_conversation, [client, launch])
      end)

      assert {:error, {:unprocessable, "branch_taken", _}} =
               Tracks.open(ctx.owner, ctx.project.id, %{branch_name: "race"})

      assert [_list, _create, %{path: "/api/conversations/c-new/terminate"}] =
               FakeTransport.calls(client)
    end

    test "a terminate that fails is logged, and the refusal is reported anyway", ctx do
      client = opening_fountain(ctx.project, false)

      FakeTransport.expect(
        client,
        %{method: "POST", path: "/api/conversations/c-new/terminate"},
        {:error, :econnrefused}
      )

      race_for_the_slug(ctx.project)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:conflict, "slug_taken", _}} =
                   Tracks.open(ctx.owner, ctx.project.id, %{title: "Kyoto"})
        end)

      assert log =~ "conversation c-new of a track that did not save was not terminated"
      assert [_list, _create, _terminate] = FakeTransport.calls(client)
    end

    test "an origin the browser made up opens a blank track", ctx do
      opening_fountain(ctx.project, false)

      # The kind arrives as text from a form and is one of four by the time it
      # reaches a row: this is the boundary, and past it nothing re-checks.
      assert {:ok, presented} =
               Tracks.open(ctx.owner, ctx.project.id, %{
                 "title" => "Kyoto",
                 "origin" => %{"kind" => "weird", "base" => "somewhere", "number" => 9}
               })

      assert presented.origin == %Origin{
               kind: :blank,
               base: "main",
               number: nil,
               title: nil,
               url: nil
             }
    end

    test "a pull request names the track, its branch and its link", ctx do
      client = opening_fountain(ctx.project, false)

      origin = %{
        "kind" => "pr",
        "base" => "feature/x",
        "number" => 12,
        "title" => "Fix the importer"
      }

      assert {:ok, presented} = Tracks.open(ctx.owner, ctx.project.id, %{"origin" => origin})
      assert presented.title == "feature/x"
      assert presented.slug == "feature-x"
      assert presented.branch == "feature/x"

      assert presented.origin == %Origin{
               kind: :pr,
               base: "feature/x",
               number: 12,
               title: "Fix the importer",
               url: "https://github.com/acme/ledger/pull/12"
             }

      [_list, create] = FakeTransport.calls(client)
      assert create.body["prompt"] =~ "pull request #12"
    end

    test "a pull request can be picked up again once its earlier track closes", ctx do
      insert_track(
        project: ctx.project,
        branch: "feature/x",
        branch_reserved: false,
        closed_at: DateTime.utc_now()
      )

      opening_fountain(ctx.project, false)
      origin = %{"kind" => "pr", "base" => "feature/x", "number" => 12}

      assert {:ok, track} = Tracks.open(ctx.owner, ctx.project.id, %{"origin" => origin})
      assert track.branch == "feature/x"
      refute Repo.get!(Track, track.id).branch_reserved
    end

    test "a pull request's branch is refused while another open track has it", ctx do
      insert_track(project: ctx.project, branch: "feature/x", branch_reserved: false)
      quiet_fountain(ctx.project)
      origin = %{"kind" => "pr", "base" => "feature/x", "number" => 12}

      assert {:error, {:unprocessable, "branch_taken", _}} =
               Tracks.open(ctx.owner, ctx.project.id, %{"origin" => origin})
    end

    test "branch origins cut a new named branch from the selected base", ctx do
      client = opening_fountain(ctx.project, false)

      assert {:ok, track} =
               Tracks.open(ctx.owner, ctx.project.id, %{
                 branch_name: "feature/import",
                 origin: %{kind: "branch", base: "release"}
               })

      assert track.title == "ravix/feature/import"
      assert track.branch == track.title
      assert track.slug == "feature-import"
      [_list, create] = FakeTransport.calls(client)
      assert create.body["prompt"] =~ "-b ravix/feature/import origin/release"
      refute create.body["prompt"] =~ "worktree add #{track.workdir} release"
    end

    test "issue origins default to the issue number and slugified title", ctx do
      opening_fountain(ctx.project, false)

      assert {:ok, track} =
               Tracks.open(ctx.owner, ctx.project.id, %{
                 origin: %{kind: "issue", number: 42, title: "Fix the importer!"}
               })

      assert track.branch == "ravix/42-fix-the-importer"
      assert track.title == track.branch
    end

    test "invalid names and historical branch reuse are refused before conversation creation",
         ctx do
      quiet_fountain(ctx.project)
      insert_track(project: ctx.project, branch: "ravix/spent", closed_at: DateTime.utc_now())

      for name <- ["two words", "bad..name", "-option", "x.lock", %{}] do
        assert {:error, {:unprocessable, "invalid_branch", _}} =
                 Tracks.open(ctx.owner, ctx.project.id, %{branch_name: name})
      end

      assert {:error, {:unprocessable, "branch_taken", _}} =
               Tracks.open(ctx.owner, ctx.project.id, %{branch_name: "spent"})
    end

    test "legacy tracks retain branches and still reserve names without the new flag", ctx do
      legacy =
        insert_track(project: ctx.project, branch: "ravix/legacy", closed_at: DateTime.utc_now())

      Repo.update_all(from(t in Track, where: t.id == ^legacy.id), set: [branch_reserved: false])
      quiet_fountain(ctx.project)

      assert {:error, {:unprocessable, "branch_taken", _}} =
               Tracks.open(ctx.owner, ctx.project.id, %{branch_name: "legacy"})

      assert Repo.get!(Track, legacy.id).branch == "ravix/legacy"
    end

    test "the database reserves branches even after a track closes", ctx do
      track =
        insert_track(
          project: ctx.project,
          branch: "ravix/reserved",
          closed_at: DateTime.utc_now()
        )

      attrs = track |> Map.from_struct() |> Map.drop([:id, :slug]) |> Map.put(:slug, "different")
      assert {:error, changeset} = Ravix.Tracks.Store.create_track(attrs)
      assert {_, _} = Keyword.fetch!(changeset.errors, :branch)
    end

    test "suggestions skip historical branches even when their workdir has another name", ctx do
      for {yard, index} <- Enum.with_index(Names.yards()) do
        insert_track(
          project: ctx.project,
          slug: "old-pr-#{index}",
          branch: "ravix/" <> Ravix.Ids.slugify(yard),
          closed_at: DateTime.utc_now()
        )
      end

      opening_fountain(ctx.project, false)
      assert {:ok, track} = Tracks.open(ctx.owner, ctx.project.id, %{})
      assert String.ends_with?(track.branch, "-2")
    end

    test "a blank track with no name gets a yard name", ctx do
      opening_fountain(ctx.project, false)
      assert {:ok, presented} = Tracks.open(ctx.owner, ctx.project.id, %{})
      assert presented.title in Enum.map(Names.yards(), &("ravix/" <> Ravix.Ids.slugify(&1)))
      assert presented.branch == "ravix/" <> presented.slug
    end

    test "a machine that refuses leaves no row behind", ctx do
      client =
        FakeTransport.client([
          {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}},
          {%{method: "POST", path: "/api/conversations"},
           {409, [], %{error: "sandbox_at_capacity", message: "busy"}}}
        ])

      stub(Ravix.Fountain, :client, fn -> client end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %Error{code: "sandbox_at_capacity"}} =
                 Tracks.open(ctx.owner, ctx.project.id, %{title: "Kyoto"})
      end)

      assert Tracks.Store.tracks_of(ctx.project.id, :all) == []
    end

    test "an opening turn that does not send is reported, and the track can be retried", ctx do
      client =
        FakeTransport.client([
          {%{method: "GET", path: "/api/conversations"},
           {200, [],
            %{data: [%{id: "c-old", sandbox_id: "sb-1", status: "idle", inserted_at: "x"}]}}},
          {%{method: "POST", path: "/api/conversations"}, {201, [], %{data: %{id: "c-new"}}}},
          {%{method: "POST", path: "/api/conversations/c-new/prompts"},
           {409, [], %{error: "sandbox_at_capacity"}}},
          {%{method: "POST", path: "/api/conversations/c-new/prompts"}, {202, [], %{}}}
        ])

      stub(Ravix.Fountain, :client, fn -> client end)

      {:ok, presented} =
        ExUnit.CaptureLog.with_log(fn ->
          Tracks.open(ctx.owner, ctx.project.id, %{title: "Kyoto"}, opening_turn: :sync)
        end)
        |> elem(0)

      track_id = presented.id
      assert_receive {:hub, %Event{name: :turn, track_id: ^track_id}}
      refute Repo.get!(Track, track_id).opened_at

      assert :ok = Tracks.retry(ctx.owner, track_id)
      assert_receive {:hub, %Event{name: :turn, track_id: ^track_id}}
      assert Repo.get!(Track, track_id).opened_at
    end

    test "a project member may cut a track; a stranger may not", ctx do
      opening_fountain(ctx.project, false)
      member = insert_user(login: "bo")
      insert_project_member(ctx.project, member)

      assert {:ok, %{role: :member, created_by_login: "bo"}} =
               Tracks.open(member, ctx.project.id, %{title: "Theirs"})

      assert {:error, :not_found} = Tracks.open(insert_user(), ctx.project.id, %{title: "Nope"})
    end

    test "without a Fountain key there are no machines", ctx do
      client = Client.new("https://managoat.com", nil)
      stub(Ravix.Fountain, :client, fn -> client end)

      assert {:error, {:unconfigured, :fountain}} =
               Tracks.open(ctx.owner, ctx.project.id, %{title: "Kyoto"})
    end
  end

  # ── talking to it ──────────────────────────────────────────────────────

  describe "prompt/3" do
    setup do
      owner = insert_user()
      project = insert_project(user: owner)
      track = insert_track(project: project, conversation_id: "c1")
      quiet_fountain(project)
      {:ok, owner: owner, project: project, track: track}
    end

    test "is accepted into the queue with its images", ctx do
      expect(Ravix.PromptQueue.Store, :enqueue, fn track_id, user_id, login, request_id, body ->
        assert track_id == ctx.track.id
        assert user_id == ctx.owner.id
        assert login == ctx.owner.login
        assert request_id == "req-1"

        # A struct, so the image that is not an image and the entry that is
        # not a map are gone by here rather than being two shapes the queue
        # has to keep tolerating.
        assert body == %Body{
                 prompt: "hello",
                 images: [%Body.Image{data: "aGk=", media_type: "image/png"}]
               }

        {:ok, %{id: request_id}}
      end)

      images = [
        %{"data" => "aGk=", "media_type" => "image/png"},
        %{"data" => "x", "media_type" => "text/plain"},
        "junk"
      ]

      assert {:ok, %{id: "req-1"}} =
               Tracks.prompt(ctx.owner, ctx.track.id, %{
                 "prompt" => "hello",
                 "images" => images,
                 "request_id" => "req-1"
               })
    end

    test "says something, or nothing is saved", ctx do
      assert {:error, {:unprocessable, "empty_prompt", _}} =
               Tracks.prompt(ctx.owner, ctx.track.id, %{prompt: "   "})
    end

    test "an image over the cap is refused before anything is saved", ctx do
      huge = String.duplicate("A", div(8 * 1024 * 1024 * 4, 3) + 1)

      assert {:error, {:unprocessable, "image_too_large", _}} =
               Tracks.prompt(ctx.owner, ctx.track.id, %{
                 prompt: "x",
                 images: [%{data: huge, media_type: "image/png"}]
               })
    end

    test "a track with no conversation, or a closed one, cannot be prompted", ctx do
      unopened = insert_track(project: ctx.project, conversation_id: nil)

      assert {:error, {:conflict, "not_open", _}} =
               Tracks.prompt(ctx.owner, unopened.id, %{prompt: "x"})

      closed =
        insert_track(project: ctx.project, conversation_id: "c9", closed_at: DateTime.utc_now())

      assert {:error, {:conflict, "closed_track", _}} =
               Tracks.prompt(ctx.owner, closed.id, %{prompt: "x"})
    end
  end

  describe "mark_read/2, interrupt/2, beat/3 and leave/2" do
    setup do
      owner = insert_user()
      project = insert_project(user: owner)
      track = insert_track(project: project, conversation_id: "c1")
      Hub.subscribe(project.id)
      {:ok, owner: owner, project: project, track: track}
    end

    test "a read mark is this person's, and the rail is told whose it is", ctx do
      assert :ok = Tracks.mark_read(ctx.owner, ctx.track.id)
      assert %DateTime{} = Ravix.People.Store.last_read_of(ctx.track.id, ctx.owner.id)
      project_id = ctx.project.id
      track_id = ctx.track.id
      user_id = ctx.owner.id

      # Named with the reader as well as the track, so that a rail can clear
      # one dot from the event alone. Not a `:tracks`: that sends every rail
      # on the project back to Fountain for a fact Fountain never held.
      assert_receive {:hub,
                      %Event{
                        name: :read,
                        project_id: ^project_id,
                        track_id: ^track_id,
                        user_id: ^user_id
                      }}

      refute_received {:hub, %Event{name: :tracks}}
    end

    test "interrupt reaches the conversation", ctx do
      client =
        FakeTransport.client([
          {%{method: "POST", path: "/api/conversations/c1/interrupt"}, {200, [], %{data: %{}}}}
        ])

      stub(Ravix.Fountain, :client, fn -> client end)
      assert :ok = Tracks.interrupt(ctx.owner, ctx.track.id)
    end

    test "presence goes through the track's door", ctx do
      assert {:ok, [%{login: login, typing: true}]} =
               Tracks.beat(ctx.owner, ctx.track.id, :typing)

      assert login == ctx.owner.login
      assert {:error, :not_found} = Tracks.beat(insert_user(), ctx.track.id, :watching)
      assert :ok = Tracks.leave(ctx.owner, ctx.track.id)
      assert Ravix.Presence.present(ctx.track.id) == []
    end
  end

  describe "events/3" do
    test "one read of the feed, prompts included, is a page; a track with no conversation an empty one" do
      owner = insert_user()
      project = insert_project(user: owner, runtime: "claude")
      track = insert_track(project: project, conversation_id: "c1")

      line =
        Jason.encode!(%{
          jsonrpc: "2.0",
          method: "session/update",
          params: %{
            update: %{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: "hi"}}
          }
        })

      # No `/turns`: the script refuses any request it does not list.
      client =
        FakeTransport.client([
          {%{
             method: "GET",
             path: "/api/conversations/c1/events",
             query: %{limit: "1000", blocks: "true", prompts: "true"}
           },
           {200, [],
            %{
              data: [
                %{
                  id: 1,
                  kind: "stage",
                  stage: "turn",
                  state: "started",
                  turn_id: "t1",
                  blocks: [%{kind: "prompt", body: "say hi"}]
                },
                %{
                  id: 2,
                  kind: "output",
                  stream: "acp",
                  data: line,
                  turn_id: "t1",
                  ts: "2026-09-09T10:00:01Z",
                  blocks: [%{kind: "text", body: "hi"}]
                }
              ],
              meta: %{has_more: false}
            }}}
        ])

      stub(Ravix.Fountain, :client, fn -> client end)
      assert {:ok, page} = Tracks.events(owner, track.id)
      assert [%Turn{id: "t1", prompt: "say hi", blocks: [%Block.Text{body: "hi"}]}] = page.turns
      assert page.last_event_id == 2

      unopened = insert_track(project: project, conversation_id: nil)
      assert {:ok, %{turns: []}} = Tracks.events(owner, unopened.id)
    end
  end

  # ── renaming and closing ───────────────────────────────────────────────

  describe "rename/3" do
    setup do
      owner = insert_user(login: "owner")
      project = insert_project(user: owner)
      cutter = insert_user(login: "cutter")
      insert_project_member(project, cutter)

      track =
        insert_track(
          project: project,
          slug: "kyoto",
          title: "Kyoto",
          branch: "cutter/kyoto",
          created_by_login: "Cutter"
        )

      {:ok, owner: owner, project: project, cutter: cutter, track: track}
    end

    test "renaming a track moves the label and nothing on the machine", ctx do
      assert :ok = Tracks.rename(ctx.owner, ctx.track.id, "Rewrite the importer")
      after_rename = Repo.get!(Track, ctx.track.id)
      assert after_rename.title == "Rewrite the importer"
      # The three that were cut on a real machine when the track opened.
      assert after_rename.slug == "kyoto"
      assert after_rename.branch == "cutter/kyoto"
      assert after_rename.workdir == "/home/sprite/work/kyoto"
      assert Tracks.Store.slug_taken?(ctx.project.id, "kyoto")
    end

    test "the cutter may rename, a mere member may not, and a name is required", ctx do
      assert :ok = Tracks.rename(ctx.cutter, ctx.track.id, "Mine")
      member = insert_user(login: "guest")
      insert_track_member(ctx.track, member)
      assert {:error, {:forbidden, _}} = Tracks.rename(member, ctx.track.id, "Theirs")

      assert {:error, {:unprocessable, "no_title", _}} =
               Tracks.rename(ctx.owner, ctx.track.id, "  ")
    end
  end

  describe "close/3" do
    setup do
      owner = insert_user()
      project = insert_project(user: owner, repo_full_name: "acme/ledger")

      track =
        insert_track(
          project: project,
          slug: "kyoto",
          conversation_id: "c1",
          branch: "ana/kyoto-1"
        )

      stub(Ravix.PromptQueue.Store, :cancel_track, fn _track_id -> :ok end)
      stub(Ravix.Previews.Lifecycle, :stop_service, fn _track_id, :cleanup -> :ok end)
      Hub.subscribe(project.id)
      {:ok, owner: owner, project: project, track: track}
    end

    defp closing_fountain(responses) do
      client =
        FakeTransport.client([
          {%{method: "POST", path: "/api/conversations/c1/prompts"},
           Keyword.get(responses, :prompt, {202, [], %{}})},
          {%{method: "POST", path: "/api/conversations/c1/terminate"},
           Keyword.get(responses, :terminate, {200, [], %{}})}
        ])

      stub(Ravix.Fountain, :client, fn -> client end)
      client
    end

    # The teardown runs under `Ravix.TaskSupervisor` after `close/3` returns.
    # `start_child/2` returns once the child exists, so by then it is either
    # still listed with this test among its callers, or already finished;
    # either way a monitor on what is listed is proof it settled, and no
    # sleep is needed.
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

    test "the row closes at once; the worktree and conversation go afterwards", ctx do
      client = closing_fountain([])
      test = self()

      # The preview stop is the first thing the teardown does and the slowest
      # in production, so it stands in for the machine: held until released.
      stub(Ravix.Previews.Lifecycle, :stop_service, fn track_id, :cleanup ->
        send(test, {:stopping, track_id, self()})

        receive do
          :released -> :ok
        end
      end)

      assert :ok = Tracks.close(ctx.owner, ctx.track.id)

      # The row and the page's news do not wait for the machine.
      assert Repo.get!(Track, ctx.track.id).closed_at
      project_id = ctx.project.id
      track_id = ctx.track.id
      assert_receive {:hub, %Event{name: :tracks, project_id: ^project_id, track_id: ^track_id}}
      assert_receive {:stopping, ^track_id, teardown}
      assert FakeTransport.calls(client) == []

      ref = Process.monitor(teardown)
      send(teardown, :released)
      assert_receive {:DOWN, ^ref, :process, ^teardown, :normal}, 5_000

      [prompt, terminate] = FakeTransport.calls(client)
      assert prompt.body["prompt"] =~ "[ravix] Close this track"
      assert prompt.body["prompt"] =~ "git worktree remove /home/sprite/work/kyoto"
      refute prompt.body["prompt"] =~ "--force"
      refute prompt.body["prompt"] =~ "git branch -D"
      assert terminate.path == "/api/conversations/c1/terminate"
    end

    test "force and the branch go in the turn only when asked", ctx do
      client = closing_fountain([])
      assert :ok = Tracks.close(ctx.owner, ctx.track.id, force: true, delete_branch: true)
      await_teardown()
      [prompt, _] = FakeTransport.calls(client)
      assert prompt.body["prompt"] =~ "git worktree remove --force /home/sprite/work/kyoto"
      assert prompt.body["prompt"] =~ "git branch -D ana/kyoto-1"
    end

    test "a machine that will not take the turn does not stop the close", ctx do
      closing_fountain(
        prompt: {409, [], %{error: "sandbox_at_capacity"}},
        terminate: {:error, :econnrefused}
      )

      stub(Ravix.Previews.Lifecycle, :stop_service, fn _track_id, :cleanup ->
        {:error, {:unavailable, "sprites", "down"}}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Tracks.close(ctx.owner, ctx.track.id)
          await_teardown()
        end)

      assert Repo.get!(Track, ctx.track.id).closed_at
      # Each refusal is logged on its own, and none stops the next.
      assert log =~ "preview of closed track #{ctx.track.id} did not stop"
      assert log =~ "close turn for track #{ctx.track.id} did not send"
      assert log =~ "conversation of closed track #{ctx.track.id} was not terminated"
      refute log =~ "fake-key"
    end

    test "a track with no conversation is closed without a turn", ctx do
      track = insert_track(project: ctx.project, slug: "quiet", conversation_id: nil)
      client = closing_fountain([])
      assert :ok = Tracks.close(ctx.owner, track.id)
      await_teardown()
      assert Repo.get!(Track, track.id).closed_at
      # The script for c1 is untouched: nothing was sent for a track with no conversation.
      assert FakeTransport.calls(client) == []
      assert :ok = Tracks.close(ctx.owner, ctx.track.id)
      await_teardown()
    end

    test "the cutter may close; a member invited to help may not", ctx do
      closing_fountain([])
      cutter = insert_user(login: ctx.track.created_by_login)
      insert_track_member(ctx.track, cutter)
      guest = insert_user()
      insert_track_member(ctx.track, guest)
      assert {:error, {:forbidden, _}} = Tracks.close(guest, ctx.track.id)
      assert :ok = Tracks.close(cutter, ctx.track.id)
      await_teardown()
    end

    test "a rebuild closes every open row without touching the machine", ctx do
      other = insert_track(project: ctx.project)
      assert :ok = Tracks.close_all_for_rebuild(ctx.project, :rebuild)
      assert Repo.get!(Track, ctx.track.id).closed_at
      assert Repo.get!(Track, other.id).closed_at
      assert Tracks.Store.tracks_of(ctx.project.id) == []
    end
  end

  # ── the machine's surfaces ─────────────────────────────────────────────

  describe "files/3, file/3 and diff/2" do
    setup do
      owner = insert_user()
      project = insert_project(user: owner)
      track = insert_track(project: project, slug: "kyoto")
      {:ok, owner: owner, project: project, track: track}
    end

    defp machine_fountain(project, extra) do
      client =
        FakeTransport.client(
          [
            {%{method: "GET", path: "/api/conversations", query: %{agent_id: project.agent_id}},
             {200, [],
              %{data: [%{id: "c1", sandbox_id: "sb-1", status: "idle", inserted_at: "x"}]}}}
          ] ++ extra
        )

      stub(Ravix.Fountain, :client, fn -> client end)
      client
    end

    test "a directory, confined, as the panel reads it", ctx do
      machine_fountain(ctx.project, [
        {%{
           method: "GET",
           path: "/api/sandboxes/sb-1/files",
           query: %{path: "/home/sprite/work/kyoto/src"}
         },
         {200, [],
          %{
            data: %{
              path: "/home/sprite/work/kyoto/src",
              entries: [%{name: "app.ts", type: "file", size: 12}],
              truncated: false
            }
          }}}
      ])

      assert {:ok,
              %{
                path: "/home/sprite/work/kyoto/src",
                entries: [%{name: "app.ts", type: "file", size: 12}],
                truncated: false
              }} =
               Tracks.files(ctx.owner, ctx.track.id, "../../../../home/sprite/work/kyoto/src")
    end

    test "a file, and the diff counted per file", ctx do
      diff = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -0,0 +1 @@\n+x"

      machine_fountain(ctx.project, [
        {%{
           method: "GET",
           path: "/api/sandboxes/sb-1/file",
           query: %{path: "/home/sprite/work/kyoto/a.txt"}
         },
         {200, [],
          %{
            data: %{
              path: "/home/sprite/work/kyoto/a.txt",
              size: 1,
              truncated: false,
              encoding: "utf-8",
              content: "x"
            }
          }}},
        {%{
           method: "GET",
           path: "/api/sandboxes/sb-1/diff",
           query: %{path: "/home/sprite/work/kyoto"}
         },
         {200, [],
          %{
            data: %{
              path: "/home/sprite/work/kyoto",
              repo_root: "/workspace/ledger",
              diff: diff,
              truncated: false
            }
          }}}
      ])

      assert {:ok, %Files.Content{content: "x", encoding: "utf-8"}} =
               Tracks.file(ctx.owner, ctx.track.id, "a.txt")

      assert {:ok,
              %Diff{
                repo_root: "/workspace/ledger",
                changes: [%Diff.Change{path: "a.txt", added: 1}]
              }} = Tracks.diff(ctx.owner, ctx.track.id)
    end

    test "no machine yet is a conflict the panel names", ctx do
      quiet_fountain(ctx.project)
      assert {:error, {:conflict, "no_machine", _}} = Tracks.files(ctx.owner, ctx.track.id, nil)
    end
  end

  describe "checks/2 and open_pull/3" do
    setup do
      owner = insert_user()

      project =
        insert_project(
          user: owner,
          repo_full_name: "acme/ledger",
          installation_id: 7,
          default_branch: "main"
        )

      track =
        insert_track(
          project: project,
          slug: "kyoto",
          title: "Kyoto",
          branch: "ana/kyoto-1",
          origin_kind: "pr",
          origin_number: 12
        )

      app = Ravix.GitHubFake.app()
      stub(Ravix.Config, :github, fn -> app end)
      {:ok, owner: owner, project: project, track: track, app: app}
    end

    test "checks are read as the installation, for this branch and this track", ctx do
      expect(Ravix.GitHub, :checks, fn app, 7, "acme/ledger", "ana/kyoto-1", narrow ->
        assert app == ctx.app
        assert narrow.origin_number == 12
        assert narrow.created_at == ctx.track.created_at
        {:ok, %{ref: "ana/kyoto-1", sha: nil, pushed: false, runs: [], pull: nil}}
      end)

      assert {:ok, %{pushed: false}} = Tracks.checks(ctx.owner, ctx.track.id)
    end

    test "a pull request is opened by the App with the track's defaults", ctx do
      expect(Ravix.GitHub, :open_pull, fn _app, 7, "acme/ledger", input ->
        assert input == %{
                 head: "ana/kyoto-1",
                 base: "main",
                 title: "Kyoto",
                 body: "Opened from Ravix track `kyoto`.",
                 draft: true
               }

        {:ok, %{number: 13, url: "https://github.com/acme/ledger/pull/13"}}
      end)

      assert {:ok, %{number: 13}} = Tracks.open_pull(ctx.owner, ctx.track.id, %{})
    end

    test "a project without a repository has nothing to check, and no App is its own refusal",
         ctx do
      bare =
        insert_track(
          project: insert_project(user: ctx.owner, repo_full_name: nil, installation_id: nil)
        )

      assert {:error, {:conflict, "no_repo", _}} = Tracks.checks(ctx.owner, bare.id)
      stub(Ravix.Config, :github, fn -> nil end)

      assert {:error, {:unconfigured, :github}} = Tracks.open_pull(ctx.owner, ctx.track.id, %{})
    end
  end
end
