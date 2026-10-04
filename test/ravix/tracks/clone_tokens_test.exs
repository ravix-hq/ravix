defmodule Ravix.Tracks.CloneTokensTest do
  use Ravix.DataCase, async: true
  import ExUnit.CaptureLog
  import Mimic
  alias Ecto.Adapters.SQL.Sandbox
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Tracks
  alias Ravix.Tracks.Sandbox.CloneTokens
  setup :verify_on_exit!

  setup do
    owner = insert_user()
    project = insert_project(user: owner, repo_full_name: "owner/repo", installation_id: 42)
    stub(Ravix.Config, :github, fn -> Ravix.GitHubFake.app() end)
    %{owner: owner, project: project}
  end

  defp running_on(track, conversation_id, status \\ "running") do
    {:ok, _} =
      Tracks.Store.create_thread(%{
        track_id: track.id,
        runtime: "claude",
        title: "Thread",
        conversation_id: conversation_id
      })

    %{id: conversation_id, status: status, sandbox_id: "box"}
  end

  defp listed(rows), do: {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: rows}}}

  defp written(vault),
    do:
      {%{method: "POST", path: "/api/vaults/#{vault}/secrets"},
       {201, [], %{data: %{key: "GITHUB_TOKEN"}}}}

  test "re-mints into the vault behind each running turn, once per vault", ctx do
    dedicated =
      insert_track(project: ctx.project, sandbox_layout: :dedicated, vault_id: "track-copy")

    shared = insert_track(project: ctx.project, sandbox_layout: :shared)
    project_vault = ctx.project.vault_id

    rows = [
      running_on(dedicated, "conv-dedicated"),
      running_on(dedicated, "conv-dedicated-codex"),
      running_on(shared, "conv-shared")
    ]

    expect(Ravix.GitHub, :mint_clone_token, 2, fn _, 42 -> {:ok, "fresh-fixture-token"} end)
    client = FakeTransport.client([listed(rows), written("track-copy"), written(project_vault)])

    assert {:ok, vaults} = CloneTokens.tick(client)
    assert Enum.sort(vaults) == Enum.sort(["track-copy", project_vault])

    for %{method: "POST"} = call <- FakeTransport.calls(client) do
      assert call.body["key"] == "GITHUB_TOKEN"
      assert call.body["value"] == "fresh-fixture-token"
    end
  end

  test "a track on a consolidated project gets its own resource's token and vault", ctx do
    resource =
      Repo.insert!(%Ravix.Projects.Resource{
        id: "resource-#{System.unique_integer([:positive])}",
        project_id: ctx.project.id,
        user_id: ctx.owner.id,
        agent_id: "resource-agent",
        environment_id: "resource-env",
        runtime: "claude",
        model: "claude-model",
        created_at: DateTime.utc_now(),
        vault_id: "resource-vault",
        installation_id: 77,
        repo_full_name: "owner/other"
      })

    track = insert_track(project: ctx.project, sandbox_layout: :shared)
    track = Repo.update!(Ecto.Changeset.change(track, resource_id: resource.id))

    expect(Ravix.GitHub, :mint_clone_token, fn _, 77 -> {:ok, "fresh-fixture-token"} end)

    client =
      FakeTransport.client([
        listed([running_on(track, "conv-resource")]),
        written("resource-vault")
      ])

    assert {:ok, ["resource-vault"]} = CloneTokens.tick(client)
  end

  test "leaves idle turns, closed tracks and repository-less projects alone", ctx do
    idle = insert_track(project: ctx.project, sandbox_layout: :dedicated, vault_id: "idle")
    closed = insert_track(project: ctx.project, sandbox_layout: :dedicated, vault_id: "closed")
    bare = insert_project(user: ctx.owner, repo_full_name: nil, installation_id: nil)
    unrepo = insert_track(project: bare, sandbox_layout: :dedicated, vault_id: "unrepo")

    rows = [
      running_on(idle, "conv-idle", "idle"),
      running_on(closed, "conv-closed"),
      running_on(unrepo, "conv-unrepo"),
      %{id: "conv-not-ours", status: "running", sandbox_id: "box"}
    ]

    Repo.update!(Ecto.Changeset.change(closed, closed_at: DateTime.utc_now()))
    reject(Ravix.GitHub, :mint_clone_token, 2)
    client = FakeTransport.client([listed(rows)])

    assert {:ok, []} = CloneTokens.tick(client)
  end

  test "a failed write is logged without the token and the other vaults still get theirs",
       ctx do
    one = insert_track(project: ctx.project, sandbox_layout: :dedicated, vault_id: "one")
    two = insert_track(project: ctx.project, sandbox_layout: :dedicated, vault_id: "two")
    rows = [running_on(one, "conv-one"), running_on(two, "conv-two")]

    expect(Ravix.GitHub, :mint_clone_token, 2, fn _, 42 -> {:ok, "fresh-fixture-token"} end)

    client =
      FakeTransport.client([
        listed(rows),
        {%{method: "POST", path: "/api/vaults/one/secrets"}, {503, [], %{error: "unavailable"}}},
        written("two")
      ])

    log = capture_log(fn -> assert {:ok, ["two"]} = CloneTokens.tick(client) end)
    assert log =~ "clone token refresh failed for vault one"
    refute log =~ "fresh-fixture-token"
  end

  test "mints nothing when Fountain cannot list conversations" do
    reject(Ravix.GitHub, :mint_clone_token, 2)

    client =
      FakeTransport.client([
        {%{method: "GET", path: "/api/conversations"}, {503, [], %{error: "unavailable"}}}
      ])

    capture_log(fn -> assert {:error, _} = CloneTokens.tick(client) end)
  end

  test "the worker ticks on its timer", ctx do
    track = insert_track(project: ctx.project, sandbox_layout: :dedicated, vault_id: "timed")
    client = FakeTransport.client([listed([running_on(track, "conv-timed")]), written("timed")])
    test = self()

    stub(Ravix.Fountain, :client, fn -> client end)

    stub(Ravix.GitHub, :mint_clone_token, fn _, 42 ->
      send(test, :minted)
      {:ok, "fresh-fixture-token"}
    end)

    pid = start_supervised!({CloneTokens, interval: false})
    allow(Ravix.Fountain, self(), pid)
    allow(Ravix.GitHub, self(), pid)
    allow(Ravix.Config, self(), pid)
    Sandbox.allow(Repo, self(), pid)

    send(pid, :tick)
    assert_receive :minted
    # The tick has returned once the process answers again.
    :sys.get_state(pid)
    assert [_, %{path: "/api/vaults/timed/secrets"}] = FakeTransport.calls(client)
  end
end
