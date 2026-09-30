defmodule Ravix.Previews.MachinePortsTest do
  @moduledoc """
  RAV-51: previewing a port on the track's machine other than the run
  script's. Which ports are offered, who may have them, and that a ticket is
  only ever minted for a port the server has seen listening.
  """
  use Ravix.DataCase, async: true, group: :preview_ports
  use Mimic

  import Ravix.PreviewsFixture

  alias Ravix.Previews
  alias Ravix.Previews.{Grant, PreviewGrant, Store}

  @ss """
  LISTEN 0      511          0.0.0.0:5173       0.0.0.0:*
  LISTEN 0      511             [::]:5173          [::]:*
  LISTEN 0      4096       127.0.0.1:3000       0.0.0.0:*
  LISTEN 0      4096   127.0.0.53%lo:53         0.0.0.0:*
  LISTEN 0      128                *:22               *:*
  LISTEN 0      511          0.0.0.0:20001      0.0.0.0:*
  garbage line
  """

  setup do
    start_tree()
    provider = start_provider()
    stub_provider(provider)
    put(provider, :listening, @ss)
    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project)
    {_token, session} = insert_session(owner)
    %{p: provider, owner: owner, project: project, track: track, session: session}
  end

  test "the picker offers what is listening, less system ports and the run-script range", ctx do
    assert {:ok, [3000, 5173]} = Previews.listening_ports(ctx.owner, ctx.track.id)

    put(ctx.p, :exec_error, :timeout)

    assert {:error, {:unavailable, "Could not read which ports are listening on this machine."}} =
             Previews.listening_ports(ctx.owner, ctx.track.id)
  end

  test "a ticket is minted only for a listening port, bound to it and to the session", ctx do
    assert {:ok, url} = Previews.open_port(ctx.owner, ctx.track.id, ctx.session.token_hash, 5173)

    %{hostname: hostname} = Store.get(ctx.track.id)
    assert url =~ ~r"^http://#{hostname}--p5173\.preview\.localhost:5183/__ravix/open#.+"

    ticket = url |> String.split("#") |> List.last()

    assert %Grant{kind: :ticket, port: 5173, session_hash: hash} =
             Store.get_grant(Ravix.Crypto.sha256(ticket), ctx.track.id, :ticket, :peek)

    assert hash == ctx.session.token_hash

    # Not listening, in the reserved range, a system port, or not a port at
    # all: no ticket, and nothing written.
    before = Repo.aggregate(PreviewGrant, :count)

    for forged <- [8080, 20_001, 22, "5173", nil, -1, 70_000] do
      assert {:error, {:unprocessable, "port", "Nothing is listening on that port yet."}} =
               Previews.open_port(ctx.owner, ctx.track.id, ctx.session.token_hash, forged)
    end

    assert Repo.aggregate(PreviewGrant, :count) == before

    assert {:error, {:unprocessable, "session", _}} =
             Previews.open_port(ctx.owner, ctx.track.id, nil, 5173)
  end

  test "a shared machine's ports take the project; a track share is not enough", ctx do
    guest = insert_user()
    insert_track_member(ctx.track, guest)
    {_token, guest_session} = insert_session(guest)

    assert {:error, :not_found} = Previews.listening_ports(guest, ctx.track.id)

    assert {:error, :not_found} =
             Previews.open_port(guest, ctx.track.id, guest_session.token_hash, 5173)

    # The run script is still theirs: that is the track's own.
    assert {:ok, _url} = Previews.open_ticket(guest, ctx.track.id, guest_session.token_hash)

    # A port grant they somehow held is not admitted either.
    row = Store.ensure(ctx.track.id)
    grant = port_grant(ctx.track.id, guest_session.token_hash, 5173)
    refute Previews.allowed?(row, grant)

    insert_project_member(ctx.project, guest)
    assert {:ok, [3000, 5173]} = Previews.listening_ports(guest, ctx.track.id)
    assert Previews.allowed?(row, grant)

    stranger = insert_user()
    assert {:error, :not_found} = Previews.listening_ports(stranger, ctx.track.id)
  end

  test "a dedicated machine is the track's own, so a track share reaches its ports", ctx do
    stub(Ravix.Config, :dedicated_rollout?, fn -> true end)
    track = insert_track(project: ctx.project, sandbox_layout: :dedicated)
    guest = insert_user()
    insert_track_member(track, guest)

    assert {:ok, [3000, 5173]} = Previews.listening_ports(guest, track.id)
  end

  test "a closed track offers no ports", ctx do
    track = insert_track(project: ctx.project, closed_at: DateTime.utc_now())

    assert {:error, _} = Previews.listening_ports(ctx.owner, track.id)
  end

  test "host labels name a port only in their own suffix" do
    assert Previews.host_label("t-abc", nil) == "t-abc"
    assert Previews.host_label("t-abc", 5173) == "t-abc--p5173"
    assert Previews.parse_host_label("t-abc--p5173") == {"t-abc", 5173}
    assert Previews.parse_host_label("t-abc") == {"t-abc", nil}

    for label <- ["t-abc--p0", "t-abc--p070", "t-abc--p65536", "t-abc--p", "--p80x"] do
      assert Previews.parse_host_label(label) == {label, nil}
    end
  end

  defp port_grant(track_id, session_hash, port) do
    grant = %Grant{
      hash: Ravix.Crypto.sha256(Ravix.Crypto.random_token()),
      track_id: track_id,
      session_hash: session_hash,
      expires: Ravix.Clock.now_ms() + 60_000,
      kind: :session,
      port: port
    }

    :ok = Store.grant(grant)
    grant
  end
end
