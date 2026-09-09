defmodule Ravix.Previews.GatewayBackendTest do
  @moduledoc """
  The backend the gateway is built against, answered by the previews
  context: host resolution, the grant checks the proxy repeats on every
  request, and the destination.
  """
  use Ravix.DataCase, async: true
  use Mimic

  import Ravix.PreviewsFixture

  alias Ravix.Previews
  alias Ravix.Previews.{GatewayBackend, Row, Store}
  alias Ravix.Tracks.Track

  setup do
    start_tree()
    provider = start_provider()
    stub_provider(provider)
    owner = insert_user()
    guest = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project, conversation_id: "c")
    insert_track_member(track, guest)
    {_token, session} = insert_session(guest)

    insert_preview_default(project,
      config: %{"directory" => ".", "command" => "run", "readinessPath" => "/"}
    )

    row = Store.ensure(track.id)

    grant = %{
      hash: "grant",
      track_id: track.id,
      session_hash: session.token_hash,
      expires: now(provider) + 60_000,
      kind: :session
    }

    assert :ok = GatewayBackend.grant_session(grant)

    %{
      p: provider,
      owner: owner,
      guest: guest,
      project: project,
      track: track,
      session: session,
      row: row,
      grant: grant
    }
  end

  test "it is the behaviour the gateway expects" do
    assert RavixWeb.PreviewGateway.Backend in (GatewayBackend.module_info(:attributes)[:behaviour] ||
                                                 [])

    assert GatewayBackend.previews_config() == %{
             domain: "preview.localhost",
             protocol: :http,
             public_port: ":5183"
           }

    assert GatewayBackend.sprites_config() == %{token: "test", base_url: "http://sprites.test"}
    assert GatewayBackend.public_url() == "http://localhost:5183"
  end

  test "hosts resolve to rows, and open tracks pass assert_open", %{row: row, track: track} do
    assert {:ok, ^row} = GatewayBackend.resolve_host(row.hostname)
    assert :error = GatewayBackend.resolve_host("t-unknown")
    assert :ok = GatewayBackend.assert_open(track.id)
    assert GatewayBackend.preview(track.id) == row
    assert %Track{id: id} = GatewayBackend.track(track.id)
    assert id == track.id

    Repo.update!(Ecto.Changeset.change(Repo.get!(Track, track.id), closed_at: DateTime.utc_now()))
    assert {:error, %{status: 409, message: message}} = GatewayBackend.assert_open(track.id)
    assert message =~ "closed"
  end

  test "grants are looked up, sessions resolve to users, and access is re-checked", %{
    guest: guest,
    track: track,
    session: session,
    grant: grant,
    row: row
  } do
    assert GatewayBackend.get_grant("grant", track.id, :session, false) == grant
    assert GatewayBackend.get_grant("grant", track.id, :ticket, false) == nil
    assert %{id: id} = GatewayBackend.session_user(session.token_hash)
    assert id == guest.id
    assert GatewayBackend.session_user("nope") == nil
    assert {:ok, %Track{closed_at: nil}} = GatewayBackend.track_access(guest, track.id)
    assert {:error, :not_found} = GatewayBackend.track_access(insert_user(), track.id)
    assert GatewayBackend.allowed?(row, grant)
  end

  test "allowed? fails when the grant, the session, the membership or the track is gone", %{
    guest: guest,
    track: track,
    session: session,
    grant: grant,
    row: row
  } do
    assert GatewayBackend.allowed?(row, grant)

    Ravix.Accounts.end_session(session.token_hash)
    refute GatewayBackend.allowed?(row, grant)
    # Ending the session cascades to the grant; a fresh session needs a fresh grant.
    assert GatewayBackend.get_grant("grant", track.id, :session, false) == nil

    {_token, session} = insert_session(guest)
    grant = %{grant | hash: "grant2", session_hash: session.token_hash}
    assert :ok = GatewayBackend.grant_session(grant)
    assert GatewayBackend.allowed?(row, grant)

    Repo.delete_all(from m in Ravix.Tracks.TrackMember, where: m.track_id == ^track.id)
    refute GatewayBackend.allowed?(row, grant)
    insert_track_member(track, guest)
    assert GatewayBackend.allowed?(row, grant)

    Previews.revoke(track.id, guest.id)
    refute GatewayBackend.allowed?(row, grant)
    assert :ok = GatewayBackend.grant_session(grant)
    assert GatewayBackend.allowed?(row, grant)

    Repo.update!(Ecto.Changeset.change(Repo.get!(Track, track.id), closed_at: DateTime.utc_now()))
    refute GatewayBackend.allowed?(row, grant)
  end

  test "info, touch, start and destination go through the context", %{
    p: p,
    track: track,
    row: row
  } do
    assert %{state: :stopped, available: true} = GatewayBackend.info(track.id)
    assert :ok = GatewayBackend.touch(track.id)
    assert Store.get(track.id).lease_until == now(p) + Previews.lease_ms()

    assert :ok = GatewayBackend.start_service(track.id)
    assert %{state: :ready} = GatewayBackend.info(track.id)
    assert {:ok, %Row{sprite: "s1", port: 20_000}} = GatewayBackend.destination(track.id)

    put(p, :sandbox, "s2")
    assert {:error, %{status: 503, message: message}} = GatewayBackend.destination(track.id)
    assert message =~ "workspace changed"
    await(p, fn _ -> match?(%Row{sprite: "s2", state: :ready}, Store.get(track.id)) end)

    Repo.update!(Ecto.Changeset.change(Repo.get!(Track, track.id), closed_at: DateTime.utc_now()))
    assert {:error, %{status: 409}} = GatewayBackend.destination(track.id)
    assert row.hostname == Store.get(track.id).hostname
  end
end
