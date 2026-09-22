Code.require_file("../credo/checks/architecture.ex", __DIR__)

defmodule Ravix.ArchitectureTest do
  use ExUnit.Case, async: true
  alias Ravix.Credo.Architecture

  setup_all do
    if is_nil(Process.whereis(Credo.Supervisor)) do
      {:ok, _} = Application.ensure_all_started(:credo)
    end

    :ok
  end

  defp issues(code, path \\ "lib/ravix/example.ex") do
    code |> Credo.SourceFile.parse(path) |> Architecture.run([])
  end

  test "strict CI actually loads and enables the architecture check" do
    {config, _} = Code.eval_file(".credo.exs")
    default = Enum.find(config.configs, &(&1.name == "default"))
    assert "credo/checks/*.ex" in default.requires
    assert {Architecture, []} in default.checks.enabled
    assert File.read!(".github/workflows/ci.yml") =~ "mix credo --strict"
  end

  test "contexts cannot reference the web layer through aliases, calls or behaviours" do
    for code <- [
          "alias RavixWeb.Error",
          "RavixWeb.Error.from(:oops)",
          "@behaviour RavixWeb.PreviewGateway.Backend",
          "alias RavixWeb.{Error, Router}"
        ] do
      assert [_ | _] = issues(code)
    end

    assert [] = issues("alias Ravix.Accounts")
    assert [] = issues("alias RavixWeb.Error", "lib/ravix_web/example.ex")
    assert [] = issues("RavixWeb.Endpoint.config_change([], [])", "lib/ravix/application.ex")
  end

  test "a page may not reach a row store, however it names one" do
    for code <- [
          "Ravix.People.Store.member?(t, u)",
          "alias Ravix.People.Store",
          "alias Ravix.Tracks.Store\nStore.get_track(id)",
          "alias Ravix.Previews.{Row, Store}\nStore.get(id)",
          "&Ravix.Projects.Store.get_project/1"
        ] do
      assert [_ | _] = issues(code, "lib/ravix_web/live/track_live.ex")
    end

    # No comment excuses it: a page has a user in hand and a door to spend it
    # at, so reaching past both is the violation rather than the thing to
    # explain.
    assert [_ | _] =
             issues(
               "# ownership: the page checked\nRavix.People.Store.member?(t, u)",
               "lib/ravix_web/live/track_live.ex"
             )

    assert [] = issues("Ravix.People.list(user, id)", "lib/ravix_web/live/track_live.ex")

    # A `Lifecycle` takes ids and asks nobody, exactly as a store does, and a
    # page may not name one either -- comment or no comment. The gateway
    # reaches what it needs through the delegates `Ravix.Previews` keeps.
    for code <- [
          "Ravix.Previews.Lifecycle.stop_service(id, :cleanup)",
          "alias Ravix.Previews.Lifecycle",
          "alias Ravix.Previews.{Lifecycle, Row}\nLifecycle.info(id)",
          "&Ravix.Previews.Lifecycle.start_service/1",
          "# ownership: the page checked\nRavix.Previews.Lifecycle.info(id)"
        ] do
      assert [_ | _] = issues(code, "lib/ravix_web/preview_gateway/ravix_backend.ex")
    end

    assert [] =
             issues("Ravix.Previews.info(id)", "lib/ravix_web/preview_gateway/ravix_backend.ex")
  end

  test "a context reaches its own store freely and another's with an explanation" do
    own = "lib/ravix/people.ex"
    own_nested = "lib/ravix/people/store.ex"
    other = "lib/ravix/tracks.ex"

    for code <- [
          "Ravix.People.Store.member?(t, u)",
          "alias Ravix.People.Store\nStore.member?(t, u)"
        ] do
      assert [] = issues(code, own)
      assert [] = issues(code, own_nested)
      assert [_] = issues(code, other)
      assert [] = issues("# ownership: Access.track_access/2 above\n" <> code, other)
    end

    # A delegate is a call site too, and the one the door in `Access` uses.
    assert [_] = issues("defdelegate member?(t, u), to: Ravix.People.Store", other)

    assert [] =
             issues(
               "# ownership: the door itself\ndefdelegate member?(t, u), to: Ravix.People.Store",
               other
             )

    # An underscored context name still resolves to its own store.
    assert [] = issues("Ravix.PromptQueue.Store.claim(id)", "lib/ravix/prompt_queue/server.ex")

    # A `Lifecycle` is judged the same way: its own context reaches it
    # freely, another says which door it came through.
    for code <- [
          "Ravix.Previews.Lifecycle.stop_service(id, :cleanup)",
          "alias Ravix.Previews.{Lifecycle, Store}\nLifecycle.retire_project(id)",
          "&Ravix.Previews.Lifecycle.stop_service/1"
        ] do
      assert [] = issues(code, "lib/ravix/previews.ex")
      assert [] = issues(code, "lib/ravix/previews/agent.ex")
      assert [_] = issues(code, other)
      assert [_] = issues(code, "lib/ravix/projects/machine.ex")
      assert [] = issues("# ownership: Access.track_access/2 above\n" <> code, other)
    end

    # The identity context's store is a store like any other: `Accounts`
    # reaches it freely, and a context turning a stored `user_id` into a row
    # says which door gave it that id.
    assert [] = issues("Ravix.Accounts.Store.get_user(id)", "lib/ravix/accounts.ex")
    assert [] = issues("Ravix.Accounts.Store.get_user(id)", "lib/ravix/accounts/access.ex")
    assert [_] = issues("Ravix.Accounts.Store.get_user(id)", "lib/ravix/projects.ex")

    assert [] =
             issues(
               "# ownership: the project's own user_id\nRavix.Accounts.Store.get_user(id)",
               "lib/ravix/projects.ex"
             )

    # Nothing else called Store or Lifecycle is implicated.
    assert [] = issues("SomeLibrary.Store.get(k)", other)
    assert [] = issues("Phoenix.LiveView.Lifecycle.attach_hook(s, :x, :m, f)", other)
  end

  # The prefix this rule was written for is gone: `Ravix.Tracks.Store` is the
  # boundary now, and nothing in `lib/` is named `_unsafe_` any more. The rule
  # stays so that reintroducing the weaker convention is still caught.
  test "remote unsafe calls and captures require an ownership explanation" do
    for code <- ["Tracks._unsafe_get_track(id)", "&Tracks._unsafe_get_track/1"] do
      assert [_] = issues(code)
      assert [] = issues("# ownership: scoped Access.track_access(user, id) above\n" <> code)
      assert [_] = issues("# ownership:\n" <> code)
      assert [_] = issues("# ownership: scoped fetch\n" <> String.duplicate("\n", 7) <> code)
    end

    assert [] = issues("_unsafe_get_track(id)")
  end

  test "a Repo call reaching another context's rows needs the same explanation" do
    previews = "lib/ravix/previews.ex"
    tracks = "lib/ravix/tracks.ex"

    # Every real context aliases the repo, so the fixtures do too.
    for body <- [
          "Repo.get(Ravix.Tracks.Track, id)",
          "alias Ravix.Tracks.Track\nRepo.get(Track, id)",
          "Repo.all(from t in Ravix.Tracks.Track, where: t.id == ^id)",
          "Repo.transaction(fn -> Repo.get(Ravix.Tracks.Track, id) end)"
        ],
        code = "alias Ravix.Repo\n" <> body do
      assert [_ | _] = issues(code, previews)
      assert [] = issues("# ownership: Access.track_access/2 above\n" <> code, previews)
      # Its own rows are its own business.
      assert [] = issues(code, tracks)
    end

    # A membership table is named after its subject and filed under it, but
    # `Ravix.People` is the context that reads and writes all seven.
    seat = "alias Ravix.Repo\nRepo.exists?(from m in Ravix.Tracks.TrackMember)"
    assert [] = issues(seat, "lib/ravix/people/store.ex")
    assert [_] = issues(seat, previews)

    # Naming a foreign module outside a Repo call is untouched: a schema's
    # `belongs_to` crosses contexts by design, and so does a supervision tree.
    assert [] = issues("belongs_to :track, Ravix.Tracks.Track", previews)
    assert [] = issues("children = [Ravix.Tracks.Follower.Supervisor]", previews)

    # And nothing outside the application is implicated.
    assert [] = issues("alias Ravix.Repo\nRepo.all(from u in SomeLibrary.Thing)", previews)
  end

  test "the tree itself obeys the rules the fixtures describe" do
    lib = Path.wildcard("lib/**/*.ex")
    assert length(lib) > 50

    for path <- lib, String.starts_with?(path, "lib/ravix_web/") do
      refute File.read!(path) =~ ~r/\bRavix\.\w+\.(Store|Lifecycle)\b/,
             "#{path} names a row store or a lifecycle; pages go through the context and Access."
    end

    for path <- lib do
      refute File.read!(path) =~ ~r/\bdef _unsafe_/,
             "#{path} defines an _unsafe_ function; the boundary is a Store module now."
    end

    # Nor by the back door: no page reads a row itself either.
    for path <- lib, String.starts_with?(path, "lib/ravix_web/") do
      refute File.read!(path) =~ ~r/\bRepo\./,
             "#{path} reads the database directly; ask a context."
    end

    # Every cross-context Repo read in the tree explains itself; `mix credo
    # --strict` is what enforces it, and this is the reminder that the count
    # is zero rather than merely small.
    #
    # Every context with unscoped row access has somewhere to put it. The
    # scoped modules keep the doors; the stores keep the rows.
    stores = Path.wildcard("lib/ravix/*/store.ex")
    assert length(stores) >= 6
    assert "lib/ravix/accounts/store.ex" in stores

    for path <- ["lib/ravix/people.ex", "lib/ravix/tracks.ex", "lib/ravix/projects.ex"] do
      refute File.read!(path) =~ ~r/\bRepo\./, "#{path} still reads rows itself"
    end

    # And the doors are one read, not one per caller.
    live = for path <- lib, File.read!(path) =~ ~r/archived_at: nil\} = project ->/, do: path
    assert live == ["lib/ravix/projects/store.ex"]
  end

  test "a scoped context's user-less functions are the ones it names" do
    # `Ravix.Tracks` and `Ravix.People` document themselves as taking the
    # signed-in user and going through `Ravix.Accounts.Access` first, and
    # the doc is what the next reader trusts instead of the call site. A
    # handful of functions do take no user --- each is asked by another
    # context about a subject it already holds, never by a page --- and this
    # is what keeps that list from growing quietly.
    #
    # A new user-less public function in one of these is not wrong; it just
    # has to be said out loud in the moduledoc, which is the moment to ask
    # whether a page could reach it.
    expected = %{
      "lib/ravix/tracks.ex" =>
        ~w(machine_of sprite_for close_all_for_rebuild present origin_info),
      "lib/ravix/people.ex" => ~w(claim_link link_target),
      # The gateway's three; everything else by id is in `Store` or `Lifecycle`.
      "lib/ravix/previews.ex" => ~w(origin by_host allowed?)
    }

    for {path, named} <- expected do
      source = File.read!(path)

      user_less =
        Regex.scan(~r/^  def ([a-z_]+[?!]?)\(([^)]*)/m, source)
        |> Enum.reject(fn [_, _name, args] -> String.contains?(args, "%User{") end)
        |> Enum.map(fn [_, name, _args] -> name end)
        |> Enum.uniq()

      assert Enum.sort(user_less) == Enum.sort(named),
             "#{path}: user-less functions are #{inspect(Enum.sort(user_less))}, " <>
               "but its documentation names #{inspect(Enum.sort(named))}. " <>
               "Add it to both, or give it the user."

      for name <- named do
        assert source =~ "`#{name}/",
               "#{path} does not mention #{name} in its documentation."
      end
    end
  end

  test "unsupervised work cannot bypass the guard through aliases or captures" do
    for code <- [
          "Task.start(fn -> :ok end)",
          "Task.async(fn -> :ok end)",
          "Task.async_stream([], & &1)",
          "alias Task, as: Work\nWork.start(fn -> :ok end)",
          "&Task.start/1",
          "import Task",
          "spawn(fn -> :ok end)",
          "Kernel.spawn_link(fn -> :ok end)",
          ":erlang.spawn(fn -> :ok end)"
        ] do
      assert [_ | _] = issues(code)
    end

    assert [] = issues("Task.Supervisor.start_child(Ravix.TaskSupervisor, fn -> :ok end)")
    assert [] = issues("start_async(socket, :load, fn -> :ok end)", "lib/ravix_web/example.ex")
    assert [] = issues("Task.async(fn -> :ok end)", "test/example_test.exs")
  end
end
