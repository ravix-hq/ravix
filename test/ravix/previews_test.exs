defmodule Ravix.PreviewsTest do
  @moduledoc """
  The route half of `server/previews.test.ts`: who may operate what,
  configuration validation, tickets, defaults, and the info shape.
  """
  use Ravix.DataCase, async: true, group: :preview_ports
  use Mimic

  import Ravix.PreviewsFixture

  alias Ravix.Previews
  alias Ravix.Previews.{Config, Row, Store}
  alias Ravix.PreviewsFixture
  alias Ravix.Sprites.Error, as: SpritesError
  alias Ravix.Tracks.Track

  setup do
    start_tree()
    provider = start_provider()
    stub_provider(provider)
    owner = insert_user()
    guest = insert_user()
    project = insert_project(user: owner)
    t1 = insert_track(project: project, conversation_id: "c1")
    t2 = insert_track(project: project, conversation_id: "c2")
    {_token, owner_session} = insert_session(owner)

    insert_preview_default(project,
      config: %{
        "directory" => "apps/demo",
        "command" => "npm run dev",
        "readinessPath" => "/health"
      }
    )

    %{
      p: provider,
      owner: owner,
      guest: guest,
      project: project,
      t1: t1,
      t2: t2,
      owner_session: owner_session
    }
  end

  test "configuration is confined to the worktree and readiness cannot select another host" do
    for directory <- ["../other", "/etc", "a/../../b", "a\0b"] do
      assert {:error, %Ecto.Changeset{errors: errors}} =
               Previews.parse_config(%{directory: directory, command: "run", readiness_path: "/"})

      assert Keyword.has_key?(errors, :directory)
    end

    for path <- ["//evil", "https://evil", "/\r\n", "/#fragment"] do
      assert {:error, %Ecto.Changeset{errors: errors}} =
               Previews.parse_config(%{directory: ".", command: "run", readiness_path: path})

      assert Keyword.has_key?(errors, :readiness_path)
    end

    assert {:error, %Ecto.Changeset{errors: errors}} =
             Previews.parse_config(%{directory: ".", command: "  ", readinessPath: "/"})

    assert Keyword.has_key?(errors, :command)

    # Every field is refused at once. A `cond` answered about the first one it
    # reached, so a form with three wrong boxes took three round trips to fix
    # and only ever pointed at one of them.
    assert {:error, %Ecto.Changeset{errors: errors}} =
             Previews.parse_config(%{directory: "/etc", command: "  ", readiness_path: "nope"})

    assert Enum.sort(Keyword.keys(errors)) == [:command, :directory, :readiness_path]

    # Not a configuration at all: nothing to hang on a field, so the error is
    # the changeset's own and `RavixWeb.Live.Form.refuse/2` leaves it for the
    # flash.
    assert {:error, %Ecto.Changeset{errors: [config: _]}} = Previews.parse_config("nope")
    assert {:ok, nil} = Previews.parse_config(nil)

    assert {:ok, %Config{directory: ".", command: "run", readiness_path: "/"}} =
             Previews.parse_config(%{
               "directory" => "  ",
               "command" => " run ",
               "readinessPath" => "/"
             })

    assert {:ok, %Config{directory: "apps/web"}} =
             Previews.parse_config(%{
               "directory" => "apps/web",
               "command" => "run",
               "readiness_path" => "/"
             })
  end

  test "members operate only their tracks, defaults remain owner controlled, closed tracks reject owners too",
       %{owner: owner, guest: guest, project: project, t1: t1} do
    assert {:error, :not_found} = Previews.status(guest, t1.id)
    insert_track_member(t1, guest)
    assert {:ok, %{state: :stopped, available: true}} = Previews.status(guest, t1.id)
    assert {:error, :not_found} = Previews.defaults(guest, project.id)
    assert {:ok, %{directory: "apps/demo"}} = Previews.defaults(owner, project.id)

    Repo.update!(Ecto.Changeset.change(Repo.get!(Track, t1.id), closed_at: DateTime.utc_now()))
    assert {:error, {:conflict, "closed_track", _}} = Previews.status(owner, t1.id)
    assert {:error, :not_found} = Previews.status(guest, t1.id)
  end

  test "info reports the override over the default, the origin, and unavailability", %{t1: t1} do
    assert %{
             available: true,
             unavailable_reason: nil,
             config: %{directory: "apps/demo", readiness_path: "/health"},
             override: nil,
             state: :stopped,
             error: nil,
             logs: "",
             url: "http://t-" <> rest
           } = Previews.info(t1.id)

    assert String.ends_with?(rest, ".preview.localhost:5183")

    override = %Config{directory: "apps/web", command: "run", readiness_path: "/"}
    assert :ok = Previews.configure(t1.id, override)
    assert %{config: ^override, override: ^override} = Previews.info(t1.id)

    stub(Ravix.Config, :sprites, fn -> nil end)

    assert %{
             available: false,
             unavailable_reason: "Previews unavailable: SPRITES_TOKEN" <> _,
             url: nil
           } = Previews.info(t1.id)

    stub(Ravix.Config, :sprites, fn -> %Ravix.Config.Sprites{token: "t", base_url: "u"} end)
    stub(Ravix.Config, :fountain, fn -> %Ravix.Config.Fountain{url: "u", key: nil} end)

    assert %{unavailable_reason: "Previews unavailable: Fountain is not configured."} =
             Previews.info(t1.id)
  end

  test "a failed startup that named a missing sprite is unavailable until the next open", %{
    p: p,
    t1: t1
  } do
    stub(Ravix.Tracks, :sprite_for, fn _ -> nil end)
    assert :ok = Previews.start_service(t1.id)
    assert %{available: false, unavailable_reason: why, state: :failed} = Previews.info(t1.id)
    assert why =~ "does not expose a Sprite"
    assert state(p).creates == 0
    stub(Ravix.Tracks, :sprite_for, fn id -> id end)
    assert :ok = Previews.start_service(t1.id)
    assert %{available: true, state: :ready} = Previews.info(t1.id)
  end

  test "a machine that cannot be reached fails the startup with a reason, not silently", %{
    p: p,
    t1: t1
  } do
    # The port check is the first thing that talks to the machine, and it is
    # reached after the old service has already been dropped. Without a clause
    # for this the `case` raised past `fail/1`, leaving the row `:starting`
    # with a nil error: the page said "Starting..." until the idle timer
    # quietly stopped it five minutes later, and nobody was ever told why.
    PreviewsFixture.put(p, :exec_error, SpritesError.new(404, "It may be asleep."))

    assert :ok = Previews.start_service(t1.id)
    assert %{state: :failed, error: error} = Previews.info(t1.id)
    assert error =~ "asleep"

    PreviewsFixture.put(p, :exec_error, nil)
    assert :ok = Previews.start_service(t1.id)
    assert %{state: :ready} = Previews.info(t1.id)
  end

  test "cleanup completes for a track whose machine is already gone", %{p: p, t1: t1} do
    assert :ok = Previews.start_service(t1.id)
    assert %Row{sprite: sprite} = Store.get(t1.id)
    assert sprite != nil

    # Releasing an activity lease on a machine that no longer exists is not
    # work left undone. Treating it as a failure kept `cleanup: true` set, and
    # the reconciler then re-ran the whole cleanup every fifteen seconds for
    # the life of the deployment.
    PreviewsFixture.put(p, :exec_error, SpritesError.new(404, "No such sprite."))
    assert :ok = Previews.stop_service(t1.id, :cleanup)

    assert %Row{sprite: nil, port: nil, stop_pending: false} = Store.get(t1.id)
  end

  test "start and stop take a word for what they are doing, and only those words", %{t1: t1} do
    # The point of the atoms over `true`/`false`: an unknown word matches no
    # clause, where a boolean typo silently meant the other thing. This is
    # the same closed vocabulary `Ravix.Fountain.Shapes` keeps for statuses.
    assert :ok = Previews.start_service(t1.id, :start)
    assert :ok = Previews.start_service(t1.id, :restart)
    assert :ok = Previews.stop_service(t1.id, :stop)
    assert :ok = Previews.stop_service(t1.id, :cleanup)

    for bad <- [true, false, :teardown, "restart"] do
      assert_raise FunctionClauseError, fn -> Previews.start_service(t1.id, bad) end
      assert_raise FunctionClauseError, fn -> Previews.stop_service(t1.id, bad) end
    end
  end

  test "touch renews the lease only on an open track", %{p: p, t1: t1} do
    assert :ok = Previews.touch(t1.id)
    assert %Row{last_activity: activity, lease_until: lease} = Store.get(t1.id)
    assert activity == now(p) and lease == now(p) + Previews.lease_ms()

    Repo.update!(Ecto.Changeset.change(Repo.get!(Track, t1.id), closed_at: DateTime.utc_now()))
    assert {:error, {:conflict, "closed_track", _}} = Previews.touch(t1.id)
  end

  test "touch renews the lease without reverting what another writer committed", %{p: p, t1: t1} do
    # The lost update the columns are for. `touch/1` used to read the whole
    # record, change its two fields, and write all nineteen back; a readiness
    # publish landing in between went back to `:starting` and the gateway kept
    # sending the reader to the start page. Here the publish happens between
    # the read and the write, and has to survive it.
    Store.save!(%{Store.ensure(t1.id) | state: :starting, generation: 4, logs: "building"})

    stale = Store.get(t1.id)
    assert stale.state == :starting

    Store.update(t1.id, state: :ready, error: nil)
    assert :ok = Previews.touch(t1.id)

    assert %Row{state: :ready, generation: 4, logs: "building"} = row = Store.get(t1.id)
    assert row.last_activity == now(p)
    assert row.lease_until == now(p) + Previews.lease_ms()
  end

  test "touch on a track whose row does not exist yet makes one and leases it", %{p: p, t2: t2} do
    assert Store.get(t2.id) == nil
    assert :ok = Previews.touch(t2.id)

    assert %Row{last_activity: activity, lease_until: lease, state: :stopped} = Store.get(t2.id)
    assert activity == now(p) and lease == now(p) + Previews.lease_ms()
  end

  test "open mints a single-use ticket on the preview origin bound to the session and starts the service",
       %{p: p, owner: owner, owner_session: session, t1: t1} do
    assert {:ok, url} = Previews.open_ticket(owner, t1.id, session.token_hash)
    row = Store.get(t1.id)
    origin = Previews.origin(row)
    assert [^origin, ticket] = String.split(url, "/__ravix/open#")

    assert %{track_id: track_id, session_hash: session_hash, kind: :ticket, expires: expires} =
             Store.get_grant(Ravix.Crypto.sha256(ticket), t1.id, :ticket, :consume)

    assert track_id == t1.id and session_hash == session.token_hash
    assert expires == now(p) + 60_000

    assert {:ok, %{open_url: open_url}} = Previews.open(owner, t1.id, session.token_hash)

    assert String.starts_with?(open_url, origin <> "/__ravix/open#")
    # The start runs in the background; the page polls info until it is ready.
    await(p, fn _ -> Store.get(t1.id).state == :ready end)

    assert {:error, :not_found} = Previews.open_ticket(insert_user(), t1.id, session.token_hash)
    await_background()
  end

  test "a refused open starts nothing, because the ticket is minted first", %{
    p: p,
    owner: owner,
    t1: t1
  } do
    assert Previews.stop(owner, t1.id) == {:ok, Previews.info(t1.id)}
    services = Map.keys(state(p).services)

    # No session hash means no ticket, which means a refusal rather than a
    # service the caller was never going to be let into.
    assert {:error, {:unprocessable, "session", _}} = Previews.open(owner, t1.id, nil)

    await_background()
    assert Map.keys(state(p).services) == services
    assert Store.get(t1.id).desired == :stopped
  end

  test "the actions configure, stop and read logs for a member, and refuse a stranger", %{
    p: p,
    owner: owner,
    guest: guest,
    t1: t1
  } do
    insert_track_member(t1, guest)
    config = %{"directory" => "apps/web", "command" => "run", "readinessPath" => "/"}

    assert {:ok, %{override: %{directory: "apps/web"}}} =
             Previews.save_config(guest, t1.id, config)

    assert {:error, %Ecto.Changeset{errors: errors}} =
             Previews.save_config(guest, t1.id, %{
               directory: "/etc",
               command: "x",
               readiness_path: "/"
             })

    assert Keyword.has_key?(errors, :directory)

    assert :ok = Previews.start_service(t1.id)
    assert {:ok, %{state: :ready, logs: "startup logs"}} = Previews.status(guest, t1.id)
    assert {:ok, %{logs: "Error: command not found"}} = Previews.logs(guest, t1.id)
    assert {:ok, %{state: :stopped}} = Previews.stop(owner, t1.id)
    assert Map.values(state(p).services) == ["stopped"]
    assert {:ok, %{override: nil}} = Previews.save_config(guest, t1.id, nil)
    assert {:error, :not_found} = Previews.stop(insert_user(), t1.id)
  end

  test "saving defaults stops the tracks that run on them and leaves overrides alone", %{
    p: p,
    owner: owner,
    guest: guest,
    project: project,
    t1: t1,
    t2: t2
  } do
    assert :ok =
             Previews.configure(t2.id, %Config{
               directory: "own",
               command: "own",
               readiness_path: "/"
             })

    Task.await_many(
      Enum.map([t1.id, t2.id], fn id -> Task.async(fn -> Previews.start_service(id) end) end),
      30_000
    )

    assert Store.get(t1.id).state == :ready and Store.get(t2.id).state == :ready

    config = %{"directory" => "apps/next", "command" => "next", "readinessPath" => "/"}
    assert {:error, :not_found} = Previews.set_defaults(guest, project.id, config)
    assert {:ok, %{directory: "apps/next"}} = Previews.set_defaults(owner, project.id, config)
    assert Store.get(t1.id).state == :stopped
    assert Store.get(t2.id).state == :ready
    assert state(p).services[service_id(t2.id)] == "running"

    assert {:ok, nil} = Previews.set_defaults(owner, project.id, nil)
    assert Store.defaults(project.id) == nil
  end

  test "stopping with cleanup revokes both kinds of grant and releases the port", %{
    owner: owner,
    owner_session: session,
    t1: t1
  } do
    assert :ok = Previews.start_service(t1.id)
    assert {:ok, _url} = Previews.open_ticket(owner, t1.id, session.token_hash)
    grant = insert_preview_agent_grant(t1, owner)
    assert Store.agent_grant(grant.hash)

    assert :ok = Previews.stop_service(t1.id, :cleanup)
    assert %Row{cleanup: true, port: nil, sprite: nil, state: :stopped} = Store.get(t1.id)
    assert Store.agent_grant(grant.hash) == nil
    assert Repo.all(Ravix.Previews.PreviewGrant) == []
    assert {:error, {:conflict, "closed_track", _}} = Previews.assert_open(t1.id)
  end

  test "revoke and revoke_agent drop one user's grants", %{
    owner: owner,
    owner_session: session,
    t1: t1
  } do
    guest = insert_user()
    {_token, guest_session} = insert_session(guest)
    insert_preview_grant(t1, session)
    insert_preview_grant(t1, guest_session)
    agent = insert_preview_agent_grant(t1, guest)

    assert :ok = Previews.revoke(t1.id, guest.id)
    assert :ok = Previews.revoke_agent(t1.id, guest.id)
    assert [%{session_hash: hash}] = Repo.all(Ravix.Previews.PreviewGrant)
    assert hash == session.token_hash
    assert Store.agent_grant(agent.hash) == nil
    assert owner.id != guest.id
  end

  test "the supervision tree is three children, the reconciler behind a cluster singleton" do
    assert [{DynamicSupervisor, _}, {Ravix.Cluster.Singleton, singleton}] =
             Previews.child_specs()

    # The tick must run on one instance, not on each of them (ADR 0003).
    assert singleton[:child] == Ravix.Previews.Reconciler
    assert singleton[:key] == "previews.reconciler"
  end

  defp service_id(track_id) do
    %Row{sprite: sprite, service: service} = Store.get(track_id)
    "#{sprite}/#{service}"
  end
end
