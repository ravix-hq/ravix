defmodule Ravix.PreviewsTest do
  @moduledoc """
  The route half of `server/previews.test.ts`: who may operate what,
  configuration validation, tickets and defaults. What happens to the
  service once somebody may operate it is `Ravix.Previews.LifecycleTest`.
  """
  use Ravix.DataCase, async: true, group: :preview_ports
  use Mimic

  import Ravix.PreviewsFixture

  alias Ravix.Previews
  alias Ravix.Previews.{Config, Lifecycle, Row, Store}
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
    assert Previews.stop(owner, t1.id) == {:ok, Lifecycle.info(t1.id)}
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

    assert :ok = Lifecycle.start_service(t1.id)
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
             Lifecycle.configure(t2.id, %Config{
               directory: "own",
               command: "own",
               readiness_path: "/"
             })

    Task.await_many(
      Enum.map([t1.id, t2.id], fn id -> Task.async(fn -> Lifecycle.start_service(id) end) end),
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
