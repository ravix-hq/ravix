defmodule Ravix.Previews.LifecycleTest do
  @moduledoc """
  The service half of `server/previews.test.ts`, by track id: what
  `Ravix.Previews.Lifecycle` does to the row and the per-track server once
  somebody has already decided the track may be touched. Who may decide is
  `Ravix.PreviewsTest`.
  """
  use Ravix.DataCase, async: true, group: :preview_ports
  use Mimic

  import Ravix.PreviewsFixture

  alias Ravix.Previews
  alias Ravix.Previews.{Config, Lifecycle, Row, Store}
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
           } = Lifecycle.info(t1.id)

    assert String.ends_with?(rest, ".preview.localhost:5183")

    override = %Config{directory: "apps/web", command: "run", readiness_path: "/"}
    assert :ok = Lifecycle.configure(t1.id, override)
    assert %{config: ^override, override: ^override} = Lifecycle.info(t1.id)

    stub(Ravix.Config, :sprites, fn -> nil end)

    assert %{
             available: false,
             unavailable_reason: "Previews unavailable: SPRITES_TOKEN" <> _,
             url: nil
           } = Lifecycle.info(t1.id)

    stub(Ravix.Config, :sprites, fn -> %Ravix.Config.Sprites{token: "t", base_url: "u"} end)
    stub(Ravix.Config, :fountain, fn -> %Ravix.Config.Fountain{url: "u", key: nil} end)

    assert %{unavailable_reason: "Previews unavailable: Fountain is not configured."} =
             Lifecycle.info(t1.id)
  end

  test "a failed startup that named a missing sprite is unavailable until the next open", %{
    p: p,
    t1: t1
  } do
    stub(Ravix.Tracks, :sprite_for, fn _ -> nil end)
    assert :ok = Lifecycle.start_service(t1.id)
    assert %{available: false, unavailable_reason: why, state: :failed} = Lifecycle.info(t1.id)
    assert why =~ "does not expose a Sprite"
    assert state(p).creates == 0
    stub(Ravix.Tracks, :sprite_for, fn id -> id end)
    assert :ok = Lifecycle.start_service(t1.id)
    assert %{available: true, state: :ready} = Lifecycle.info(t1.id)
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

    assert :ok = Lifecycle.start_service(t1.id)
    assert %{state: :failed, error: error} = Lifecycle.info(t1.id)
    assert error =~ "asleep"

    PreviewsFixture.put(p, :exec_error, nil)
    assert :ok = Lifecycle.start_service(t1.id)
    assert %{state: :ready} = Lifecycle.info(t1.id)
  end

  test "cleanup completes for a track whose machine is already gone", %{p: p, t1: t1} do
    assert :ok = Lifecycle.start_service(t1.id)
    assert %Row{sprite: sprite} = Store.get(t1.id)
    assert sprite != nil

    # Releasing an activity lease on a machine that no longer exists is not
    # work left undone. Treating it as a failure kept `cleanup: true` set, and
    # the reconciler then re-ran the whole cleanup every fifteen seconds for
    # the life of the deployment.
    PreviewsFixture.put(p, :exec_error, SpritesError.new(404, "No such sprite."))
    assert :ok = Lifecycle.stop_service(t1.id, :cleanup)

    assert %Row{sprite: nil, port: nil, stop_pending: false} = Store.get(t1.id)
  end

  test "start and stop take a word for what they are doing, and only those words", %{t1: t1} do
    # The point of the atoms over `true`/`false`: an unknown word matches no
    # clause, where a boolean typo silently meant the other thing. This is
    # the same closed vocabulary `Ravix.Fountain.Shapes` keeps for statuses.
    assert :ok = Lifecycle.start_service(t1.id, :start)
    assert :ok = Lifecycle.start_service(t1.id, :restart)
    assert :ok = Lifecycle.stop_service(t1.id, :stop)
    assert :ok = Lifecycle.stop_service(t1.id, :cleanup)

    for bad <- [true, false, :teardown, "restart"] do
      assert_raise FunctionClauseError, fn -> Lifecycle.start_service(t1.id, bad) end
      assert_raise FunctionClauseError, fn -> Lifecycle.stop_service(t1.id, bad) end
    end
  end

  test "touch renews the lease only on an open track", %{p: p, t1: t1} do
    assert :ok = Lifecycle.touch(t1.id)
    assert %Row{last_activity: activity, lease_until: lease} = Store.get(t1.id)
    assert activity == now(p) and lease == now(p) + Previews.lease_ms()

    Repo.update!(Ecto.Changeset.change(Repo.get!(Track, t1.id), closed_at: DateTime.utc_now()))
    assert {:error, {:conflict, "closed_track", _}} = Lifecycle.touch(t1.id)
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
    assert :ok = Lifecycle.touch(t1.id)

    assert %Row{state: :ready, generation: 4, logs: "building"} = row = Store.get(t1.id)
    assert row.last_activity == now(p)
    assert row.lease_until == now(p) + Previews.lease_ms()
  end

  test "touch on a track whose row does not exist yet makes one and leases it", %{p: p, t2: t2} do
    assert Store.get(t2.id) == nil
    assert :ok = Lifecycle.touch(t2.id)

    assert %Row{last_activity: activity, lease_until: lease, state: :stopped} = Store.get(t2.id)
    assert activity == now(p) and lease == now(p) + Previews.lease_ms()
  end

  test "stopping with cleanup revokes both kinds of grant and releases the port", %{
    owner: owner,
    owner_session: session,
    t1: t1
  } do
    assert :ok = Lifecycle.start_service(t1.id)
    assert {:ok, _url} = Previews.open_ticket(owner, t1.id, session.token_hash)
    grant = insert_preview_agent_grant(t1, owner)
    assert Store.agent_grant(grant.hash)

    assert :ok = Lifecycle.stop_service(t1.id, :cleanup)
    assert %Row{cleanup: true, port: nil, sprite: nil, state: :stopped} = Store.get(t1.id)
    assert Store.agent_grant(grant.hash) == nil
    assert Repo.all(Ravix.Previews.PreviewGrant) == []
    assert {:error, {:conflict, "closed_track", _}} = Lifecycle.assert_open(t1.id)
  end
end
