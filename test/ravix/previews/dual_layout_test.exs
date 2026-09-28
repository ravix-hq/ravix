defmodule Ravix.Previews.DualLayoutTest do
  use Ravix.DataCase, async: true, group: :preview_ports
  use Mimic
  import Ravix.PreviewsFixture

  alias Ravix.Crypto
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Previews
  alias Ravix.Previews.{Agent, Lifecycle, Store}
  alias Ravix.Tracks.Track

  setup do
    provider = start_provider()
    stub_provider(provider, machine: false)
    client = FakeTransport.client([])
    stub(Ravix.Fountain, :client, fn -> client end)
    owner = insert_user()
    project = insert_project(user: owner)

    tracks =
      for id <- ["s1", "s2"],
          do:
            insert_track(
              project: project,
              conversation_id: "conversation-#{id}",
              sandbox_layout: :dedicated,
              sandbox_id: id,
              sandbox_generation: 1
            )

    insert_preview_default(project,
      config: %{directory: ".", command: "run", readiness_path: "/"}
    )

    %{provider: provider, owner: owner, project: project, tracks: tracks, client: client}
  end

  test "preview services and destinations follow each dedicated track, and tickets remain scoped",
       ctx do
    [one, two] = ctx.tracks
    member = insert_user()
    membership = insert_track_member(one, member)
    {_token, session} = insert_session(member)

    for track <- ctx.tracks do
      assert :ok = Lifecycle.start_service(track.id)
      assert {:ok, row} = Lifecycle.destination(track.id)
      assert row.sandbox_id == track.sandbox_id
      assert row.sprite == track.sandbox_id
      assert row.state == :ready
    end

    assert {:ok, url} = Previews.open_ticket(member, one.id, session.token_hash)
    ticket = url |> String.split("#") |> List.last() |> Crypto.sha256()
    assert grant = Store.get_grant(ticket, one.id, :ticket, :consume)
    assert is_nil(Store.get_grant(ticket, one.id, :ticket, :consume))
    assert {:error, :not_found} = Previews.open_ticket(member, two.id, session.token_hash)
    assert {:error, :not_found} = Previews.open(member, two.id, session.token_hash)
    # A consumed ticket cannot be reused even on the admitted track.
    refute Previews.allowed?(Store.get(one.id), grant)
    assert {:ok, url} = Previews.open_ticket(member, one.id, session.token_hash)
    ticket = url |> String.split("#") |> List.last() |> Crypto.sha256()
    grant = Store.get_grant(ticket, one.id, :ticket, :peek)
    assert Previews.allowed?(Store.get(one.id), grant)
    refute Previews.allowed?(Store.get(two.id), grant)
    Repo.delete!(membership)
    refute Previews.allowed?(Store.get(one.id), grant)
    insert_track_member(one, member)
    Repo.delete!(session)
    refute Previews.allowed?(Store.get(one.id), grant)
    assert FakeTransport.calls(ctx.client) == []
  end

  test "plain run scripts use each dedicated machine and keep allocations separate", ctx do
    assert {:ok, _} =
             Previews.set_defaults(ctx.owner, ctx.project.id, %{directory: ".", command: "worker"})

    for track <- ctx.tracks do
      assert {:ok, %{state: :running, url: nil}} = Previews.run(ctx.owner, track.id)
      row = Store.get(track.id)
      assert row.sprite == track.sandbox_id
      assert {:ok, %{state: :running}} = Previews.run(ctx.owner, track.id, :restart)
      assert {:ok, %{state: :stopped}} = Previews.stop(ctx.owner, track.id)
    end

    [one, two] = Enum.map(ctx.tracks, &Store.get(&1.id))
    assert one.port == two.port
    refute one.sprite == two.sprite
  end

  test "a startup from an older sandbox generation cannot publish ready", ctx do
    [track | _] = ctx.tracks

    put(ctx.provider, :ready, fn ->
      Repo.update!(Ecto.Changeset.change(Repo.get!(Track, track.id), sandbox_generation: 2))
      true
    end)

    assert :ok = Lifecycle.start_service(track.id)
    assert %{state: :failed, error: message} = Store.get(track.id)
    assert message =~ "workspace changed during startup"
  end

  test "shared project retirement leaves dedicated services and generations alone", ctx do
    [track | _] = ctx.tracks
    assert :ok = Lifecycle.start_service(track.id)
    before = Store.get(track.id)
    assert :ok = Lifecycle.retire_project(ctx.project.id)
    assert Store.get(track.id) == before
    assert state(ctx.provider).deletes == []
  end

  test "agent helper generation and sandbox identity are checked against the selected track",
       ctx do
    [one, two] = ctx.tracks
    prompt = insert_prompt(track: one, user: ctx.owner, status: "sending")
    assert Previews.prepare_agent_preview(prompt) =~ "preview tools"

    [_, token] =
      Regex.run(
        ~r/Authorization: Bearer ([A-Za-z0-9_-]+)/,
        List.last(state(ctx.provider).execs) |> Enum.at(2)
      )

    grant = Store.agent_grant(Crypto.sha256(token))
    assert grant.sandbox_id == "s1"
    assert grant.sandbox_generation == 1
    assert {:ok, _} = Agent.route(one.id, "Bearer " <> token, %{action: "status"})
    assert {:error, _} = Agent.route(two.id, "Bearer " <> token, %{action: "status"})
    Repo.update!(Ecto.Changeset.change(one, sandbox_generation: 2))

    assert {:error, {:conflict, "preview_replaced", _}} =
             Agent.route(one.id, "Bearer " <> token, %{action: "status"})
  end
end
