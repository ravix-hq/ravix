defmodule Ravix.Previews.StoreTest do
  use Ravix.DataCase, async: true, group: :preview_ports

  alias Ravix.Previews.{Preview, Row, Store}

  describe "rows" do
    test "ensure creates a stopped row once and get reads it back by track and by host" do
      track = insert_track()
      assert Store.get(track.id) == nil

      row = Store.ensure(track.id)
      assert %Row{track_id: track_id, state: :stopped, desired: :stopped, generation: 0} = row
      assert track_id == track.id
      assert row.service == "sy-" <> row.hostname
      assert Store.ensure(track.id) == row
      assert Store.get(track.id) == row
      assert Store.by_host(row.hostname) == row
      assert Store.by_host("nope") == nil
      assert row in Store.all()
    end

    test "a saved row round-trips through the columns" do
      track = insert_track()
      row = Store.ensure(track.id)

      config = %{directory: "apps/web", command: "run", readiness_path: "/health"}

      saved = %{
        row
        | config: config,
          applied_config: Row.fingerprint(config),
          desired: :running,
          state: :ready,
          last_activity: 5,
          lease_until: 6,
          unavailable: "why"
      }

      assert :ok = Store.save(saved)
      assert Store.get(track.id) == saved

      # The columns are the record: every field is its own, and `desired` and
      # `state` come back as atoms because `Ecto.Enum` and a CHECK agree on
      # the set.
      stored = Repo.get!(Preview, track.id)

      assert %Preview{
               desired: :running,
               state: :ready,
               last_activity: 5,
               lease_until: 6,
               stop_pending: false,
               generation: 0,
               logs: "",
               unavailable: "why"
             } = stored

      assert stored.config == %{
               "directory" => "apps/web",
               "command" => "run",
               "readiness_path" => "/health"
             }
    end

    test "the expand-phase document is written alongside the columns" do
      # Until the release that reads `previews.row` is gone, every write puts
      # the same record in both places. The migration that drops the column
      # takes this test with it.
      track = insert_track()
      row = Store.ensure(track.id)
      assert :ok = Store.save(%{row | state: :ready, last_activity: 5})

      stored = Repo.get!(Preview, track.id)

      assert stored.row["state"] == "ready"
      assert stored.row["last_activity"] == 5
      assert stored.row["track_id"] == track.id
      assert stored.row["service"] == stored.service
    end

    test "update writes the named fields and leaves every other one alone" do
      # What a whole-document write could not do, and the reason for the
      # columns: `Ravix.Previews.touch/1` used to read nineteen fields, change
      # two, and write nineteen back, reverting whatever committed between.
      track = insert_track()
      row = Store.ensure(track.id)
      assert :ok = Store.save(%{row | state: :starting, generation: 7, logs: "building"})

      # Another writer publishes readiness, as `publish_ready` does.
      assert Store.update(track.id, state: :ready) == 1

      # And the lease writer sets only its own two fields, on the row as it
      # now is rather than the one it last read.
      assert Store.update(track.id, last_activity: 42, lease_until: 99) == 1

      assert %Row{
               state: :ready,
               generation: 7,
               logs: "building",
               last_activity: 42,
               lease_until: 99
             } = Store.get(track.id)
    end

    test "update on a track with no row moves nothing and does not raise" do
      assert Store.update(insert_track().id, state: :ready) == 0
    end

    test "allocate hands out distinct ports per sprite from 20000, keeps a held port, and the index refuses a duplicate" do
      [a, b, c] = for _ <- 1..3, do: insert_track()

      assert {:ok, %Row{port: 20_000, sprite: "sp", sandbox_id: "sb"}} =
               Store.allocate(a.id, "sb", "sp")

      assert {:ok, %Row{port: 20_001}} = Store.allocate(b.id, "sb", "sp")
      assert {:ok, %Row{port: 20_000}} = Store.allocate(c.id, "other", "other-sprite")
      assert {:ok, %Row{port: 20_000}} = Store.allocate(a.id, "sb", "sp")

      # A new sprite means a new allocation, and the old port is free again.
      assert {:ok, %Row{port: 20_000, sprite: "sp2", applied_config: nil}} =
               Store.allocate(a.id, "sb2", "sp2")

      assert {:ok, %Row{port: 20_000, sprite: "sp"}} = Store.allocate(c.id, "sb", "sp")

      row = Store.get(b.id)
      assert {:error, %Ecto.Changeset{errors: [port: _]}} = Store.save(%{row | port: 20_000})
    end
  end

  describe "browser grants" do
    setup do
      user = insert_user()
      {_token, session} = insert_session(user)
      track = insert_track(project: insert_project(user: user))
      %{user: user, session: session, track: track}
    end

    test "a ticket is single use, a session grant is not, and expiry hides both", %{
      session: s,
      track: t
    } do
      now = System.system_time(:millisecond)

      ticket = %{
        hash: "h1",
        track_id: t.id,
        session_hash: s.token_hash,
        expires: now + 1000,
        kind: :ticket
      }

      assert :ok = Store.grant(ticket)
      assert Store.get_grant("h1", t.id, :session, :peek) == nil
      assert Store.get_grant("h1", "other", :ticket, :peek) == nil
      assert Store.get_grant("h1", t.id, :ticket, :peek) == ticket
      assert Store.get_grant("h1", t.id, :ticket, :consume) == ticket
      assert Store.get_grant("h1", t.id, :ticket, :peek) == nil

      session = %{ticket | hash: "h2", kind: :session}
      assert :ok = Store.grant(session)
      assert Store.get_grant("h2", t.id, :session, :peek) == session
      assert Store.get_grant("h2", t.id, :session, :peek) == session

      assert :ok = Store.grant(%{session | hash: "h3", expires: now - 1})
      assert Store.get_grant("h3", t.id, :session, :peek) == nil
      # Expired grants are swept when the next one is written.
      assert :ok = Store.grant(%{session | hash: "h4"})
      assert Repo.get(Ravix.Previews.PreviewGrant, "h3") == nil
    end

    test "revoke drops a track's grants, or only one user's", %{user: user, session: s, track: t} do
      other = insert_user()
      {_token, other_session} = insert_session(other)
      now = System.system_time(:millisecond)

      for {hash, session_hash} <- [{"a", s.token_hash}, {"b", other_session.token_hash}] do
        :ok =
          Store.grant(%{
            hash: hash,
            track_id: t.id,
            session_hash: session_hash,
            expires: now + 1000,
            kind: :session
          })
      end

      Store.revoke(t.id, user.id)
      assert Store.get_grant("a", t.id, :session, :peek) == nil
      assert Store.get_grant("b", t.id, :session, :peek) != nil
      Store.revoke(t.id)
      assert Store.get_grant("b", t.id, :session, :peek) == nil
    end
  end

  describe "agent grants" do
    test "one per track, replaced on grant, hidden when expired, revoked by track or user" do
      user = insert_user()
      track = insert_track(project: insert_project(user: user), conversation_id: "c")
      now = System.system_time(:millisecond)

      grant = %{
        hash: "g1",
        track_id: track.id,
        user_id: user.id,
        conversation_id: "c",
        prompt_id: "p1",
        sandbox_id: "sb",
        sprite: "sp",
        expires: now + 1000
      }

      assert :ok = Store.grant_agent(grant)
      assert Store.agent_grant("g1") == grant
      assert :ok = Store.grant_agent(%{grant | hash: "g2"})
      assert Store.agent_grant("g1") == nil
      assert Store.agent_grant("g2").hash == "g2"

      assert :ok = Store.grant_agent(%{grant | hash: "g3", expires: now - 1})
      assert Store.agent_grant("g3") == nil

      assert :ok = Store.grant_agent(%{grant | hash: "g4"})
      Store.revoke_agent(track.id, insert_user().id)
      assert Store.agent_grant("g4") != nil
      Store.revoke_agent(track.id, user.id)
      assert Store.agent_grant("g4") == nil

      # The factory's camelCase document reads too.
      camel = insert_preview_agent_grant(insert_track(), user)
      assert %{track_id: track_id, sandbox_id: "sandbox-" <> _} = Store.agent_grant(camel.hash)
      assert track_id == camel.track_id
    end
  end

  test "defaults are per project and cleared with nil" do
    project = insert_project()
    assert Store.defaults(project.id) == nil
    config = %{directory: ".", command: "run", readiness_path: "/"}
    assert :ok = Store.set_defaults(project.id, config)
    assert Store.defaults(project.id) == config
    assert :ok = Store.set_defaults(project.id, %{config | command: "run2"})
    assert Store.defaults(project.id).command == "run2"
    assert :ok = Store.set_defaults(project.id, nil)
    assert Store.defaults(project.id) == nil

    # The factory's document reads too.
    camel = insert_preview_default(insert_project())

    assert Store.defaults(camel.project_id) == %{
             directory: ".",
             command: "npm run dev",
             readiness_path: "/"
           }
  end
end
