defmodule Ravix.Previews.AgentTest do
  @moduledoc """
  `server/agent-previews.test.ts` and the agent half of `previews.test.ts`:
  the shell helper itself, the visible prompt, and what the helper's
  credential may and may not do.
  """
  use Ravix.DataCase, async: true
  use Mimic

  import Ravix.PreviewsFixture

  alias Ravix.Previews
  alias Ravix.Previews.{Agent, Store}
  alias Ravix.PromptQueue.Item
  alias Ravix.Tracks.Track
  alias RavixWeb.Error

  defmodule Upstream do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, body, conn} = read_body(conn)
      send(owner, {:request, get_req_header(conn, "authorization"), Jason.decode!(body)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"data":{"state":"stopped"}}))
    end
  end

  test "the actual shell helper preserves command JSON and authenticates without printing its credential" do
    token = "test-agent-capability-not-a-provider-token"
    pid = start_supervised!({Bandit, plug: {Upstream, self()}, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)

    dir = Path.join(System.tmp_dir!(), "ravix-agent-helper-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "preview.sh")
    File.write!(path, Agent.script("http://127.0.0.1:#{port}/api/tracks/t1/preview/agent", token))
    File.chmod!(path, 0o600)

    config = %{
      "directory" => "apps/it's web",
      "command" => ~s|npm run dev -- --port "$PORT"; echo "$(literal)"|,
      "readinessPath" => "/"
    }

    for args <- [["configure", Jason.encode!(config)], ["status"], ["configure", "null"]] do
      {out, code} = System.cmd("sh", [path | args], stderr_to_stdout: true)
      assert code == 0
      refute out =~ token
    end

    assert_received {:request, ["Bearer " <> ^token],
                     %{"action" => "configure", "config" => ^config}}

    assert_received {:request, ["Bearer " <> ^token], %{"action" => "status"}}
    assert_received {:request, ["Bearer " <> ^token], %{"action" => "configure", "config" => nil}}

    {_out, code} = System.cmd("sh", [path, "arbitrary-endpoint"], stderr_to_stdout: true)
    assert code == 2
    refute_received {:request, _, _}
  end

  test "tool instructions are removed for display while the user's words remain intact" do
    original = "[from @ana] Configure my preview\nthen show the result"

    wrapped =
      "#{Agent.start_marker()}\ninternal instructions\n#{Agent.end_marker()}\n\n#{original}"

    assert Agent.visible_prompt(wrapped) == original
    assert Agent.visible_prompt(original) == original
    incomplete = "#{Agent.start_marker()}\nordinary unfinished text"
    assert Agent.visible_prompt(incomplete) == incomplete
  end

  describe "the installed helper" do
    setup context do
      start_tree()
      provider = start_provider()
      stub_provider(provider)
      owner = insert_user()
      guest = insert_user()
      project = insert_project(user: owner)
      t1 = insert_track(project: project, conversation_id: "t1")
      t2 = insert_track(project: project, conversation_id: "t2")

      insert_preview_default(project,
        config: %{
          "directory" => "apps/demo",
          "command" => "npm run dev",
          "readinessPath" => "/health"
        }
      )

      user = if context[:guest], do: guest, else: owner
      if context[:guest], do: insert_track_member(t1, guest)

      prompt = insert_prompt(track: t1, user: user, status: "sending")
      instructions = Previews.prepare_agent_preview(prompt)

      [_, token] =
        Regex.run(
          ~r/Authorization: Bearer ([A-Za-z0-9_-]+)/,
          List.last(state(provider).execs) |> Enum.at(2)
        )

      call = fn action, config, track_id, credential ->
        Agent.route(track_id, "Bearer " <> credential, %{"action" => action, "config" => config})
      end

      %{
        p: provider,
        owner: owner,
        guest: guest,
        user: user,
        project: project,
        t1: t1,
        t2: t2,
        prompt: prompt,
        instructions: instructions,
        token: token,
        call: call
      }
    end

    @tag :guest
    test "configures and starts only its track without granting browser access", %{
      p: p,
      t1: t1,
      t2: t2,
      project: project,
      instructions: instructions,
      token: token,
      call: call
    } do
      refute instructions =~ token
      assert instructions =~ "/home/sprite/.ravix/previews/#{t1.id}.sh"
      assert instructions =~ "#{project.id}/t/#{t1.id}"
      assert instructions =~ "hosts under .preview.localhost"
      assert hd(state(p).execs) |> Enum.at(2) =~ "umask 077"

      assert {:error, %Error{status: 401}} = call.("status", nil, t2.id, token)

      assert {:error, %Error{status: 422, code: "preview_action"}} =
               call.("open", nil, t1.id, token)

      assert {:error, %Error{status: 422}} = call.("project-defaults", nil, t1.id, token)

      config = %{
        "directory" => "apps/web",
        "command" => ~s(npm run dev -- --port "$PORT" --strictPort),
        "readinessPath" => "/"
      }

      assert {:ok, %{override: %{directory: "apps/web"}, track_url: url}} =
               call.("configure", config, t1.id, token)

      assert url == "http://localhost:5183/p/#{project.id}/t/#{t1.id}"
      assert Store.defaults(project.id).directory == "apps/demo"

      assert {:ok, data} = call.("start", nil, t1.id, token)
      refute Map.has_key?(data, :open_url)
      await(p, fn _ -> Store.get(t1.id).state == :ready end)
      assert {:ok, %{logs: "Error: command not found"}} = call.("logs", nil, t1.id, token)
      assert {:ok, %{state: :stopped}} = call.("stop", nil, t1.id, token)
      assert {:ok, %{override: nil}} = call.("configure", nil, t1.id, token)
    end

    @tag :guest
    test "capabilities expire, rotate, and remain revoked after removal and reinvitation", %{
      p: p,
      guest: guest,
      t1: t1,
      prompt: prompt,
      token: token,
      call: call
    } do
      hash = Ravix.Crypto.sha256(token)
      grant = Store.agent_grant(hash)
      assert :ok = Store.grant_agent(%{grant | expires: now(p) - 1})
      assert {:error, %Error{status: 401}} = call.("status", nil, t1.id, token)
      assert :ok = Store.grant_agent(%{grant | expires: now(p) + 60_000})
      assert {:ok, _} = call.("status", nil, t1.id, token)

      # Removal revokes; reinvitation does not resurrect.
      Repo.delete_all(from m in Ravix.Tracks.TrackMember, where: m.track_id == ^t1.id)
      Previews.revoke_agent(t1.id, guest.id)
      insert_track_member(t1, guest)
      assert {:error, %Error{status: 401}} = call.("configure", nil, t1.id, token)

      # The next turn rotates the credential; the old one stays dead.
      Previews.prepare_agent_preview(prompt)
      assert {:error, %Error{status: 401}} = call.("status", nil, t1.id, token)
    end

    test "rejects cancelled turns, replacement conversations, changed sandboxes and closed tracks",
         %{
           p: p,
           t1: t1,
           prompt: prompt,
           token: token,
           call: call
         } do
      set_status = fn status ->
        Repo.update!(Ecto.Changeset.change(Repo.get_by!(Item, id: prompt.id), status: status))
      end

      set_status.(:cancelled)
      assert {:error, %Error{status: 401}} = call.("status", nil, t1.id, token)
      set_status.(:sent)
      assert {:ok, _} = call.("status", nil, t1.id, token)

      Repo.update!(Ecto.Changeset.change(Repo.get!(Track, t1.id), conversation_id: "replacement"))
      assert {:error, %Error{status: 401}} = call.("status", nil, t1.id, token)
      Repo.update!(Ecto.Changeset.change(Repo.get!(Track, t1.id), conversation_id: "t1"))

      put(p, :sandbox, "s2")

      assert {:error, %Error{status: 409, code: "preview_replaced"}} =
               call.("configure", nil, t1.id, token)

      put(p, :sandbox, "s1")

      Repo.update!(Ecto.Changeset.change(Repo.get!(Track, t1.id), closed_at: DateTime.utc_now()))

      assert {:error, %Error{status: 409, code: "closed_track"}} =
               call.("status", nil, t1.id, token)
    end

    test "unavailable previews and malformed credentials are refused", %{
      t1: t1,
      token: token,
      call: call
    } do
      assert {:error, %Error{status: 401}} = Agent.route(t1.id, nil, %{"action" => "status"})

      assert {:error, %Error{status: 401}} =
               Agent.route(t1.id, "Bearer short", %{"action" => "status"})

      stub(Ravix.Config, :sprites, fn -> nil end)

      assert {:error, %Error{status: 501, code: "preview_unavailable"}} =
               call.("status", nil, t1.id, token)
    end

    @tag :guest
    test "grants are revoked by track cleanup", %{t1: t1, token: token, call: call} do
      assert {:ok, _} = call.("status", nil, t1.id, token)
      assert :ok = Previews.stop_service(t1.id, true)
      assert {:error, %Error{status: 401}} = call.("status", nil, t1.id, token)
    end
  end

  test "helper preparation that fails leaves the prompt runnable and no grant behind" do
    start_tree()
    provider = start_provider()
    stub_provider(provider)
    owner = insert_user()
    track = insert_track(project: insert_project(user: owner), conversation_id: "c")
    prompt = insert_prompt(track: track, user: owner, status: "sending")

    stub(Ravix.Sprites, :exec, fn _cfg, _sprite, _argv, _timeout ->
      {:ok, %{stdout: "", stderr: "denied", code: 1}}
    end)

    note = Previews.prepare_agent_preview(prompt)
    assert note =~ "could not be prepared this turn"
    assert String.starts_with?(note, Agent.start_marker())
    assert Repo.all(Ravix.Previews.PreviewAgentGrant) == []

    stub(Ravix.Tracks, :sprite_for, fn _ -> nil end)
    assert Previews.prepare_agent_preview(prompt) =~ "could not be prepared"

    stub(Ravix.Config, :previews, fn -> nil end)
    assert Previews.prepare_agent_preview(prompt) == ""
  end
end
