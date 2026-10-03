defmodule Ravix.Tooling.PreviewToolsTest do
  use Ravix.DataCase, async: true, group: :preview_ports
  use Mimic

  import Ravix.PreviewsFixture
  import Ravix.ToolingFixture

  alias Ravix.{Previews, Tooling}
  alias Ravix.Previews.{PreviewGrant, Store}
  alias Ravix.Sprites.Error, as: SpritesError
  alias Ravix.Tooling.{OAuth, PreviewCatalog, Receipt}

  setup do
    provider = start_provider()
    stub_provider(provider)
    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project)
    {p, _, _} = principal(owner)
    %{provider: provider, owner: owner, project: project, track: track, p: p}
  end

  test "project defaults, track overrides and resets persist through the scoped tools", c do
    config = %{"directory" => ".", "command" => "worker", "stop_command" => "stop-worker"}
    defaults = %{"project_id" => c.project.id, "config" => config, "request_id" => "defaults"}
    assert {:ok, %{config: saved}} = Tooling.call(c.p, "update_preview_defaults", defaults)
    assert saved.command == "worker"
    assert {:ok, %{config: ^saved}} = Tooling.call(c.p, "get_preview_defaults", defaults_id(c))
    assert {:ok, %{config: ^saved, override: nil}} = call(c, "get_preview_config")

    override = Map.put(config, "command", "track-worker")

    assert {:ok, %{override: %{command: "track-worker"}}} =
             call(c, "update_preview_config", %{"config" => override})

    assert Store.get(c.track.id).config.command == "track-worker"

    assert {:ok, %{config: ^saved, override: nil}} =
             call(c, "update_preview_config", %{"reset" => true, "request_id" => "reset"})

    assert Store.get(c.track.id).config == nil

    assert {:ok, %{config: nil}} =
             Tooling.call(
               c.p,
               "update_preview_defaults",
               Map.merge(defaults_id(c), %{"reset" => true, "request_id" => "clear"})
             )

    assert {:ok, nil} = Previews.defaults(c.owner, c.project.id)
  end

  test "run and start join, restart runs once per request, stop persists, and no grants are minted",
       c do
    configure(c)
    assert {:ok, %{state: :starting}} = call(c, "run_preview")
    await_background()
    assert {:ok, %{state: :running, open_url: nil}} = Previews.status(c.owner, c.track.id)
    assert {:ok, %{state: :running}} = call(c, "start_preview")
    await_background()
    assert state(c.provider).creates == 1

    assert {:ok, first} = call(c, "restart_preview")
    await_background()
    assert state(c.provider).creates == 2
    assert {:ok, replay} = call(c, "restart_preview")
    assert replay == Jason.decode!(Jason.encode!(first))
    assert state(c.provider).creates == 2

    assert {:ok, result} = call(c, "preview_status")
    assert result.state == :running
    refute Map.has_key?(result, :open_url)
    assert {:ok, %{state: :stopped}} = call(c, "stop_preview")
    assert Store.get(c.track.id).desired == :stopped
    assert Repo.aggregate(PreviewGrant, :count) == 0

    assert Enum.all?(Repo.all(Receipt), fn receipt ->
             not Map.has_key?(receipt.result, "open_url")
           end)
  end

  test "configuration writes stop running services and replay without stopping later runs", c do
    configure(c)
    assert {:ok, _} = call(c, "run_preview")
    await_background()
    attrs = %{"config" => %{"directory" => "apps", "command" => "new-worker"}}
    assert {:ok, first} = call(c, "update_preview_config", attrs)
    assert first.state == :stopped
    assert Store.get(c.track.id).config.command == "new-worker"
    assert {:ok, _} = call(c, "start_preview")
    await_background()
    assert {:ok, _} = call(c, "update_preview_config", attrs)
    assert {:ok, %{state: :running}} = call(c, "preview_status")

    assert {:error, {:conflict, "request_id_used", _}} =
             call(c, "update_preview_config", %{"reset" => true})
  end

  test "read-only guests can read their track but cannot use the machine or project defaults",
       c do
    guest = insert_user()
    insert_track_member(c.track, guest, role: :read)
    {p, _, _} = principal(guest)
    c = %{c | p: p}

    for name <- ~w(get_preview_config preview_status preview_logs) do
      assert {:ok, _} = call(c, name)
    end

    for name <- ~w(run_preview start_preview restart_preview stop_preview update_preview_config) do
      assert {:error, {:forbidden, _}} = call(c, name, %{"reset" => true} |> mutation_args(name))
    end

    for name <- ~w(get_preview_defaults update_preview_defaults) do
      assert {:error, :not_found} = Tooling.call(p, name, tool_args(c, name))
    end

    assert state(c.provider).creates == 0
    assert Repo.aggregate(Receipt, :count) == 0
  end

  test "outsiders, sibling track IDs and removed membership never reach mutations", c do
    guest = insert_user()
    membership = insert_track_member(c.track, guest)
    sibling = insert_track(project: c.project)
    {p, _, _} = principal(guest)
    assert {:error, :not_found} = Tooling.call(p, "preview_status", %{"track_id" => sibling.id})
    Repo.delete!(membership)

    for tool <- PreviewCatalog.tools() do
      assert {:error, :not_found} = Tooling.call(p, tool.name, tool_args(c, tool.name))
    end

    assert Repo.aggregate(Receipt, :count) == 0
    assert state(c.provider).reads == 0
  end

  test "scope denial, disconnected grants and expired credentials prevent every tool", c do
    {limited, _, _} = principal(c.owner, "mcp", ["projects:read"])

    for tool <- PreviewCatalog.tools() do
      assert {:error, {:forbidden, _}} = Tooling.call(limited, tool.name, tool_args(c, tool.name))
    end

    OAuth.disconnect(c.owner, c.p.grant.id)

    for tool <- PreviewCatalog.tools() do
      assert {:error, :unauthenticated} = Tooling.call(c.p, tool.name, tool_args(c, tool.name))
    end

    {expired, _, _} = principal(c.owner)

    Ravix.Tooling.Store.credential(Ravix.Crypto.sha256(expired.token))
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:error, :unauthenticated} =
             Tooling.call(expired, "preview_status", tool_args(c, "preview_status"))

    assert Repo.aggregate(Receipt, :count) == 0
  end

  test "revocation during a provider read suppresses logs", c do
    configure(c)
    assert {:ok, _} = call(c, "run_preview")
    await_background()

    stub(Ravix.Sprites, :service_logs, fn _, _, _ ->
      OAuth.disconnect(c.owner, c.p.grant.id)
      {:ok, "private output"}
    end)

    assert {:error, :unauthenticated} = call(c, "preview_logs")
  end

  test "membership removal during a provider read suppresses logs", c do
    configure(c)
    assert {:ok, _} = call(c, "run_preview")
    await_background()
    guest = insert_user()
    membership = insert_track_member(c.track, guest)
    {p, _, _} = principal(guest)

    stub(Ravix.Sprites, :service_logs, fn _, _, _ ->
      Repo.delete!(membership)
      {:ok, "private output"}
    end)

    assert {:error, :not_found} = call(%{c | p: p}, "preview_logs")
  end

  test "logs are a bounded Unicode tail in status, logs and durable receipts", c do
    configure(c)
    assert {:ok, _} = call(c, "run_preview")
    await_background()
    logs = String.duplicate("α", 6000) <> "last"
    stub(Ravix.Sprites, :service_logs, fn _, _, _ -> {:ok, logs} end)
    assert {:ok, %{logs: "last", logs_truncated: true}} = call(c, "preview_logs", %{"limit" => 4})
    assert {:ok, %{logs: tail, logs_truncated: true}} = call(c, "preview_status")
    assert String.length(tail) == 4000
    assert String.ends_with?(tail, "last")
    assert String.valid?(tail)
    assert byte_size(tail) <= 16_000
    assert {:ok, %{logs: ^tail, logs_truncated: true}} = call(c, "stop_preview")
  end

  test "combining characters cannot bypass the log byte bound", c do
    configure(c)
    assert {:ok, _} = call(c, "run_preview")
    await_background()
    logs = "a" <> String.duplicate("\u0301", 20_000) <> String.duplicate("😀", 4001)
    stub(Ravix.Sprites, :service_logs, fn _, _, _ -> {:ok, logs} end)
    assert {:ok, %{logs: tail, logs_truncated: true}} = call(c, "preview_logs")
    assert tail == String.duplicate("😀", 4000)
    assert byte_size(tail) == 16_000
  end

  test "provider failures report failed startup and log errors; mutation failures retain claims",
       c do
    configure(c)
    put(c.provider, :exec_error, SpritesError.new(502, "offline"))
    assert {:ok, _} = call(c, "start_preview")
    await_background()
    assert {:ok, %{state: :failed, error: error}} = call(c, "preview_status")
    assert is_binary(error) and error != ""
    put(c.provider, :exec_error, nil)
    assert {:ok, _} = call(c, "restart_preview")
    await_background()

    stub(Ravix.Sprites, :service_logs, fn _, _, _ ->
      {:error, SpritesError.new(502, "offline")}
    end)

    assert {:error, _} = call(c, "preview_logs")
    put(c.provider, :fail_stop, true)
    assert {:error, _} = call(c, "stop_preview")
    assert {:error, {:conflict, "operation_unconfirmed", _}} = call(c, "stop_preview")
  end

  test "missing and invalid configuration is refused without changing persisted config", c do
    for attrs <- [
          %{},
          %{"reset" => false},
          %{"reset" => true, "config" => %{"directory" => ".", "command" => "worker"}}
        ] do
      assert {:error, {:unprocessable, "invalid_arguments", _}} =
               call(c, "update_preview_config", attrs)
    end

    assert Repo.aggregate(Receipt, :count) == 0

    assert {:error, %Ecto.Changeset{}} =
             call(c, "update_preview_config", %{
               "config" => %{"directory" => "../other", "command" => "worker"}
             })

    assert Store.get(c.track.id) == nil

    assert {:error, {:conflict, "operation_unconfirmed", _}} =
             call(c, "update_preview_config", %{
               "config" => %{"directory" => "../other", "command" => "worker"}
             })

    assert {:ok, _} =
             call(c, "update_preview_config", %{"reset" => true, "request_id" => "corrected"})
  end

  test "closed tracks refuse config and run operations", c do
    c.track |> Ecto.Changeset.change(closed_at: DateTime.utc_now()) |> Repo.update!()

    for name <-
          ~w(get_preview_config preview_status preview_logs run_preview start_preview restart_preview stop_preview update_preview_config) do
      assert {:error, {:conflict, "closed_track", _}} =
               Tooling.call(c.p, name, tool_args(c, name))
    end

    assert state(c.provider).creates == 0
  end

  test "an in-flight mutation refuses duplicate work and later replays its receipt", c do
    configure(c)
    assert {:ok, _} = call(c, "run_preview")
    await_background()
    caller = self()

    stub(Ravix.Sprites, :service_action, fn _, _, _, action ->
      if action == :stop do
        send(caller, {:stopping, self()})
        receive do: (:finish_stop -> :ok)
      end

      {:ok, ""}
    end)

    task = Task.async(fn -> call(c, "stop_preview") end)
    assert_receive {:stopping, worker}, 5000
    assert {:error, {:conflict, "operation_unconfirmed", _}} = call(c, "stop_preview")
    send(worker, :finish_stop)
    assert {:ok, first} = Task.await(task)
    assert {:ok, replay} = call(c, "stop_preview")
    assert replay == Jason.decode!(Jason.encode!(first))
    refute_received {:stopping, _}
  end

  test "a write permission downgrade during a mutation suppresses its response and replay", c do
    configure(c)
    assert {:ok, _} = call(c, "run_preview")
    await_background()
    guest = insert_user()
    membership = insert_track_member(c.track, guest, role: :write)
    {p, _, _} = principal(guest)

    stub(Ravix.Sprites, :service_action, fn _, _, _, action ->
      if action == :stop do
        membership |> Ecto.Changeset.change(role: :read) |> Repo.update!()
      end

      {:ok, ""}
    end)

    c = %{c | p: p}
    assert {:error, {:forbidden, _}} = call(c, "stop_preview")
    assert {:error, {:forbidden, _}} = call(c, "stop_preview")
    assert {:ok, %{state: :stopped}} = call(c, "preview_status")
  end

  defp configure(c),
    do: Previews.save_config(c.owner, c.track.id, %{directory: ".", command: "worker"})

  defp defaults_id(c), do: %{"project_id" => c.project.id}
  defp mutation_args(args, "update_preview_config"), do: args
  defp mutation_args(_, _), do: %{}

  defp tool_args(c, name) do
    args =
      if name in ~w(get_preview_defaults update_preview_defaults),
        do: defaults_id(c),
        else: %{"track_id" => c.track.id}

    args =
      if name in ~w(update_preview_defaults update_preview_config),
        do: Map.put(args, "reset", true),
        else: args

    if name in ~w(get_preview_defaults get_preview_config preview_status preview_logs),
      do: args,
      else: Map.put(args, "request_id", name)
  end

  defp call(c, name, attrs \\ %{}),
    do: Tooling.call(c.p, name, Map.merge(tool_args(c, name) |> Map.delete("reset"), attrs))
end
