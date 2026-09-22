defmodule RavixWeb.WorkspaceLive do
  @moduledoc "The project rail, inbox, navigation, and project management forms."
  use RavixWeb, :live_view

  alias Ravix.{Accounts, Hub, Projects, Tracks}
  alias Ravix.Hub.Event
  alias Ravix.Tracks.Names
  alias RavixWeb.Live.Form
  alias RavixWeb.Live.Guard

  # The four origins. One list rather than the three that had grown -- this
  # module's guard, the buttons in the template, and `Ravix.Tracks.Track`'s
  # own -- since the day they disagree is the day the form offers something
  # the context refuses.
  #
  # They stay as `Track.origin_kinds/0` gives them: atoms. They used to be
  # mapped through `to_string/1` here and then, four clauses into the event
  # handler, mapped back with `%{"branch" => :branches, ...}`. The strings
  # existed only because the buttons send strings, which is one boundary and
  # is `@form_origins`' whole job.
  @origin_kinds Ravix.Tracks.Track.origin_kinds()
  @form_origins Map.new(@origin_kinds, &{to_string(&1), &1})
  @origin_labels %{blank: "Blank", branch: "Branch", pr: "Pull request", issue: "Issue"}
  @origin_refs %{branch: :branches, pr: :pulls, issue: :issues}

  # The six dialogs, as the buttons spell them and as this module does.
  @dialogs %{
    "search" => :search,
    "new-project" => :new_project,
    "new-track" => :new_track,
    "settings" => :settings,
    "people" => :people,
    "account" => :account
  }

  @doc "The origin buttons on the new-track form, in the order they are offered."
  @spec origin_choices() :: [{Ravix.Tracks.Track.origin_kind(), String.t()}]
  def origin_choices, do: Enum.map(@origin_kinds, &{&1, @origin_labels[&1]})

  @impl true
  def mount(_params, session, socket) do
    socket =
      assign(socket,
        session_token: session["session_token"],
        github_available: Accounts.capabilities().github,
        projects: [],
        tracks: %{},
        # How many tracks across every project want somebody. Counted where
        # the rail is read rather than in the template, which asked for it
        # four times a render --- twice in the sidebar badge and twice in the
        # inbox heading --- and each ask walked every track of every project.
        attention: 0,
        expanded_projects: MapSet.new(),
        advanced_track: false,
        project: nil,
        track_id: nil,
        # The nested `RavixWeb.TrackLive`, once it has said where it is. See
        # the `:track_host` clause of `handle_info/2`, and `hand_over/3`.
        track_host: nil,
        dialog: nil,
        project_form: Form.new(:new_project),
        track_form: Form.new(:new_track),
        repos: [],
        installations: [],
        installation: nil,
        refs: [],
        origin_kind: :blank,
        query: "",
        # Creating a project and creating a track, and nothing else. The
        # settings dialog owns its own; see `RavixWeb.Live.SettingsDialog`
        # for why one flag for the whole page could not answer "may I press
        # this".
        busy: false
      )

    {:ok, if(socket.assigns.current_user, do: reload(socket), else: socket)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = validate_session(socket)

    case wrong_page(socket) do
      nil -> {:noreply, open_url(socket, params)}
      to -> {:noreply, push_navigate(socket, to: to)}
    end
  end

  # Which of the two pages this LiveView is the URL entitled to, if not the one
  # it named. There is no marketing page: the domain is the product. A stranger
  # is sent to sign in from wherever they landed, and somebody already signed in
  # never sees `/login`, because the workspace is what they came back for.
  #
  # The third page is the first-run walkthrough, and only the three places
  # somebody lands without having chosen anything send them to it. A URL that
  # names a project is somewhere to be already; see
  # `Ravix.Accounts.needs_onboarding?/2` for who is left alone.
  defp wrong_page(%{assigns: %{current_user: nil, live_action: :login}}), do: nil
  defp wrong_page(%{assigns: %{current_user: nil}}), do: "/login"
  defp wrong_page(%{assigns: %{live_action: :login}}), do: "/"

  defp wrong_page(%{assigns: %{live_action: action} = assigns})
       when action in [:home, :projects, :inbox] do
    if Accounts.needs_onboarding?(assigns.current_user, length(assigns.projects)),
      do: "/welcome"
  end

  defp wrong_page(_socket), do: nil

  defp open_url(socket, params) do
    project = Enum.find(socket.assigns.projects, &(&1.id == params["project"]))
    track_id = params["track"]

    valid_track =
      is_nil(track_id) or
        Enum.any?(socket.assigns.tracks[params["project"]] || [], &(&1.id == track_id))

    if params["project"] && (is_nil(project) or not valid_track) do
      socket
      |> put_flash(:error, "That project or track is no longer available.")
      |> push_patch(to: "/")
    else
      select_project(socket, project, track_id, params)
    end
  end

  defp select_project(socket, project, track_id, params) do
    # Expand the project being opened, but only when it is a different one
    # than was open before. Every patch lands here -- dismissing a dialog,
    # following a track link -- and re-expanding on each would undo a collapse
    # the reader just made on the group they are working in.
    previous = socket.assigns[:project]
    arriving? = project && (is_nil(previous) || previous.id != project.id)

    expanded = socket.assigns.expanded_projects
    expanded = if arriving?, do: MapSet.put(expanded, project.id), else: expanded

    socket =
      socket
      |> hand_over(project, track_id)
      |> assign(
        project: project,
        track_id: track_id,
        dialog: nil,
        expanded_projects: expanded
      )

    if params["new"] == "track" && project && project.access != :tracks do
      open_dialog(socket, :new_track)
    else
      socket
    end
  end

  # Move the nested track page to the track that was just chosen, rather than
  # letting it be torn down and built again.
  #
  # `live_render/3` keys the child on its DOM id, so an id with the track in
  # it meant every switch unmounted one LiveView and mounted another: a join,
  # a fresh access check, `allow_upload/3` and the hooks all over again, and a
  # page with nothing on it until the first read answered. The id is fixed
  # now, and this is what moves it.
  #
  # The track handed over is the one already in the rail --- this page read it
  # for the list on the left, through `Ravix.Tracks.list/2` and this person's
  # own access --- so the child can draw the right title, branch and status in
  # the same patch that asks for the rest. It is a head start and not an
  # authority: `RavixWeb.TrackLive` checks the person against the new track
  # before it renders a thing, and replaces all of it with what
  # `Ravix.Tracks.get/3` answers.
  #
  # Nothing is sent when the track is not changing, because every patch comes
  # through here --- opening a dialog, dismissing one --- and a hand-over is a
  # reload of the page on the right.
  defp hand_over(socket, project, track_id) do
    track =
      project && track_id &&
        Enum.find(socket.assigns.tracks[project.id] || [], &(&1.id == track_id))

    if track && socket.assigns.track_host && socket.assigns.track_id != track_id do
      send(socket.assigns.track_host, {:select_track, project, track})
    end

    socket
  end

  # A URL patch is not a message, so no hook has run for it; this is where a
  # patch establishes that there is still somebody here. It asks the guard
  # rather than the database, so a burst of patches -- opening a dialog,
  # dismissing it, following a track link -- costs one read between them
  # rather than one each. See `RavixWeb.Live.Guard`.
  defp validate_session(%{assigns: %{current_user: nil}} = socket), do: socket

  defp validate_session(socket) do
    hash = Ravix.Crypto.sha256(socket.assigns.session_token)

    case Guard.verify(socket.assigns[:session_guard], hash) do
      {:ok, guard} -> assign(socket, session_guard: guard)
      :error -> assign(socket, current_user: nil, projects: [], tracks: %{}, attention: 0)
    end
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, reload_async(socket)}

  def handle_event("dismiss", _, socket) do
    socket = assign(socket, dialog: nil)

    {:noreply,
     if(socket.assigns.project,
       do:
         push_patch(socket,
           to: "/p/#{socket.assigns.project.id}" <> track_suffix(socket.assigns.track_id)
         ),
       else: socket
     )}
  end

  def handle_event("toggle-project", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded_projects

    if Enum.any?(socket.assigns.projects, &(&1.id == id)) do
      expanded =
        if MapSet.member?(expanded, id),
          do: MapSet.delete(expanded, id),
          else: MapSet.put(expanded, id)

      {:noreply, assign(socket, expanded_projects: expanded)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("advanced-track", _, socket) do
    if socket.assigns.advanced_track do
      # Collapsing only hides the origin controls; `hidden` does not disable an
      # input, so the ref select underneath still submits. Put the origin back
      # to blank so the form cannot open a track from a ref nobody can see.
      {:noreply, assign(socket, advanced_track: false, origin_kind: :blank, refs: [])}
    else
      {:noreply, assign(socket, advanced_track: true)}
    end
  end

  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, query: q)}

  def handle_event("edit", %{"new_project" => params}, socket),
    do: {:noreply, assign(socket, project_form: Form.new(:new_project, params))}

  def handle_event("edit", %{"new_track" => params}, socket),
    do: {:noreply, assign(socket, track_form: Form.new(:new_track, params))}

  def handle_event("dialog", %{"name" => name}, socket) when is_map_key(@dialogs, name),
    do: {:noreply, open_dialog(socket, Map.fetch!(@dialogs, name))}

  def handle_event("installation", %{"installation" => id}, socket) do
    case Integer.parse(id) do
      {id, ""} -> {:noreply, load_repos(socket, id)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("create-project", %{"new_project" => params}, socket) do
    repo = Enum.find(socket.assigns.repos, &(&1.full_name == params["repo"]))
    attrs = Map.take(params, ["name"])

    attrs =
      if repo,
        do:
          Map.merge(attrs, %{"repo" => repo.full_name, "installation_id" => repo.installation_id}),
        else: attrs

    user = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(busy: true, project_form: Form.new(:new_project, params))
     |> traced_async(:create_project, fn -> created(Projects.create(user, attrs), user) end)}
  end

  def handle_event("origin", %{"kind" => word}, socket) when is_map_key(@form_origins, word) do
    kind = Map.fetch!(@form_origins, word)
    socket = assign(socket, origin_kind: kind, refs: [], advanced_track: true)

    case @origin_refs[kind] do
      nil ->
        {:noreply, socket}

      refs_kind ->
        # A GitHub call, and it used to be one this process waited out: the
        # rail stopped drawing and the dialog stopped answering for as long
        # as the repository took to list its branches. The form's own
        # "Create track" stays disabled until the refs land, which is what
        # already said "not yet" while this was synchronous too.
        user = socket.assigns.current_user
        id = project_id(socket)
        {:noreply, traced_async(socket, :refs, fn -> Projects.refs(user, id, refs_kind) end)}
    end
  end

  def handle_event("create-track", %{"new_track" => params}, socket) do
    kind = socket.assigns.origin_kind
    ref = Enum.find(socket.assigns.refs, &(ref_id(&1) == params["ref"]))

    # `Tracks.open/4` takes browser-shaped attrs and does its own narrowing of
    # the kind against `Track.origin_kinds/0` (`read_origin/2`), so the word
    # goes back over that boundary as a string -- the context is not to start
    # trusting this page more than it trusts an HTTP body.
    word = to_string(kind)

    origin =
      case {kind, ref} do
        {:branch, %{} = r} -> %{kind: word, base: r.name}
        {:pr, %{} = r} -> %{kind: word, number: r.number, title: r.title, base: r.base_ref}
        {:issue, %{} = r} -> %{kind: word, number: r.number, title: r.title}
        _ -> %{kind: "blank"}
      end

    user = socket.assigns.current_user
    id = project_id(socket)
    attrs = %{title: params["title"], origin: origin}

    {:noreply,
     socket
     |> assign(busy: true, track_form: Form.new(:new_track, params))
     |> traced_async(:create_track, fn -> created(Tracks.open(user, id, attrs), user) end)}
  end

  @impl true
  def handle_async(:create_project, {:ok, response}, socket) do
    {:noreply,
     result(
       assign(socket, busy: false),
       response,
       fn s, {p, rail} -> s |> apply_rail(rail) |> push_patch(to: "/p/#{p.id}") end,
       :project_form
     )}
  end

  def handle_async(:create_track, {:ok, response}, socket) do
    {:noreply,
     result(
       assign(socket, busy: false),
       response,
       fn s, {t, rail} ->
         s |> apply_rail(rail) |> push_patch(to: "/p/#{t.project_id}/t/#{t.id}")
       end,
       :track_form
     )}
  end

  def handle_async(:refs, {:ok, response}, socket),
    do: {:noreply, result(socket, response, &assign(&1, refs: &2))}

  def handle_async(:repos, {:ok, response}, socket) do
    {:noreply,
     result(socket, response, fn s, data ->
       assign(s,
         repos: data.repos,
         installations: data.installations,
         installation: data.selected
       )
     end)}
  end

  # One project's tracks, in the place the rail keeps them. A project that has
  # gone since the read started is not put back.
  def handle_async({:tracks, id}, {:ok, {:ok, tracks}}, socket) do
    if Enum.any?(socket.assigns.projects, &(&1.id == id)) do
      tracks = Map.put(socket.assigns.tracks, id, tracks)
      {:noreply, assign(socket, tracks: tracks, attention: attention_count(tracks))}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:tracks, _id}, {:ok, {:error, _reason}}, socket), do: {:noreply, socket}

  # The rail is what `handle_params/3` decides from, and a rail that arrived
  # on its own has no patch coming to decide again. So the two decisions a
  # patch would make are made here: a project that is open and no longer
  # listed is left, and a person whose last project just went is sent to the
  # walkthrough exactly as a mount would send them.
  def handle_async(:reload, {:ok, rail}, socket) do
    socket = apply_rail(socket, rail)

    cond do
      socket.assigns.project &&
          not Enum.any?(socket.assigns.projects, &(&1.id == socket.assigns.project.id)) ->
        {:noreply, push_patch(socket, to: "/")}

      to = wrong_page(socket) ->
        {:noreply, push_navigate(socket, to: to)}

      true ->
        {:noreply, socket}
    end
  end

  # A rail read that crashed leaves the rail showing what it had. The clause
  # below belongs to the two reads somebody pressed a button for; saying "the
  # operation could not finish" about a refresh nobody asked for is an error
  # message for something that was not an operation.
  def handle_async(name, {:exit, _reason}, socket)
      when name == :reload
      when elem(name, 0) == :tracks,
      do: {:noreply, socket}

  def handle_async(_name, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(busy: false)
       |> put_flash(:error, "The operation could not finish. Refresh and try again.")}

  # The rail shows a track's title, branch, status and last activity, and
  # which projects exist at all. Two events cannot move any of that and are
  # dropped rather than reloaded: who is *looking* at a track, and a track's
  # prompt queue, which this page does not render. The queue is the one
  # worth naming, because it moves on every prompt sent, delivered or
  # cancelled, and re-listing every project's tracks for each of those was
  # the largest thing this page did for no visible reason.
  #
  # A turn is the other. It is the most frequent event left --- one at the
  # start and one at the end of everything an agent does, on every project
  # this person can see --- and the only thing it can move is the status,
  # activity and unread mark of the tracks of the project it names. So it
  # re-reads that project's tracks and nothing else. It used to re-read the
  # whole rail, and a rail read is `Ravix.Tracks.list/2` per project, each of
  # which asks Fountain for that project's conversations *live* (the sidebar's
  # status dot must not lag a turn ending, so it refuses the memo). Somebody
  # with five projects therefore paid five or more round trips, in this
  # process, with the page unable to render or answer a click for the whole
  # of them, every time any agent anywhere started or finished a turn.
  #
  # Everything else reloads the rail entire, because `:people` can change
  # which projects exist at all and `:tracks` and `:settings` can change the
  # project itself. A narrower rule for those would have to know which of the
  # rail's fields each event can reach, and getting that wrong shows up as a
  # status dot that is quietly a minute stale.
  @impl true
  # The nested track page saying where it is, on its own mount.
  #
  # A nested LiveView has no `handle_params/3` and reads its session once, at
  # mount, so the only way to move one that is already mounted to a different
  # track is to tell it. It knows this process --- `socket.parent_pid` --- and
  # this process does not know it until it says so, which is why the
  # introduction runs this way round rather than the other.
  def handle_info({:track_host, pid}, socket), do: {:noreply, assign(socket, track_host: pid)}

  # The people dialog did the removal. Either way the rail is now wrong --
  # a project you just left goes, and a project you took somebody off has a
  # different set of tracks under it -- so it is re-read and the dialog
  # closes behind it.
  def handle_info({:person_removed, :project, _login}, socket),
    do: {:noreply, socket |> reload_async() |> push_patch(to: "/")}

  # A `live_component` cannot put a flash in the page's own socket, so it
  # sends the sentence here; see `RavixWeb.Live.Result.error/2`.
  def handle_info({:flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  # The settings dialog saved a project's settings, which may have renamed
  # it. The rail on the left is showing the old name until it is re-read.
  def handle_info(:project_settings_saved, socket), do: {:noreply, reload_async(socket)}

  # The agent panel's clock; see `RavixWeb.Live.AgentPanel`.
  def handle_info({:agent_panel, id, tick}, socket) do
    send_update(RavixWeb.Live.AgentPanel, id: id, tick: tick)
    {:noreply, socket}
  end

  # The account dialog connected or replaced what pays for this person's
  # agent. The person on the page is now out of date, and the dialog has
  # already said what replacing it means for open tracks.
  def handle_info({:agent_connected, %Accounts.User{} = user}, socket) do
    {:noreply,
     socket
     |> assign(current_user: user)
     |> put_flash(:info, "#{agent_name(user)} is connected. New projects are built with it.")}
  end

  # The account dialog removed something the person held. When it was what
  # paid for their agent, the projects they own have nothing to run on until
  # they connect another; the dialog has already said so, and stays open.
  def handle_info({:agent_disconnected, %Accounts.User{} = user}, socket) do
    message =
      if Accounts.Inference.connected?(user),
        do: "Removed.",
        else:
          "Removed. Projects you own have nothing to run on until you connect #{agent_name(user)} again."

    {:noreply, socket |> assign(current_user: user) |> put_flash(:info, message)}
  end

  # A rebuild closed every track on the project and a delete removed it
  # outright. Either way this is no longer somewhere to be, and a component
  # cannot patch the URL.
  def handle_info(:project_left_behind, socket),
    do: {:noreply, socket |> reload_async() |> push_patch(to: "/")}

  def handle_info({:hub, %Event{name: name}}, socket) when name in [:here, :queue],
    do: {:noreply, socket}

  def handle_info({:hub, %Event{name: :turn, project_id: id}}, socket),
    do: {:noreply, refresh_tracks(socket, id)}

  def handle_info({:hub, %Event{}}, socket), do: {:noreply, reload_async(socket)}

  # The rail, read here and now. Mount has nothing to draw until this answers
  # and `handle_params/3` decides whether the URL names a project this person
  # still has, so it waits, and it is the only caller that does. A button
  # pressed, a dialog closing behind a change it made, a hub event: every
  # rail read after mount goes through `reload_async/1`, because a rail read
  # is every project's tracks and the page is drawing nothing while it runs.
  defp reload(%{assigns: %{current_user: nil}} = socket), do: socket
  defp reload(socket), do: apply_rail(socket, read_rail(socket.assigns.current_user))

  defp reload_async(%{assigns: %{current_user: nil}} = socket), do: socket

  defp reload_async(socket) do
    user = socket.assigns.current_user
    traced_async(socket, :reload, fn -> read_rail(user) end)
  end

  # The two creates, once they have something to show. The page patches to
  # what was created, and `handle_params/3` will only open a project that is
  # in the rail, so the rail is read here, in the task that did the creating,
  # and arrives in the same answer. Off this process, as every rail read after
  # mount is, and in hand before the patch, which a `reload_async/1` could
  # not promise.
  defp created({:ok, value}, user), do: {:ok, {value, read_rail(user)}}
  defp created(response, _user), do: response

  defp refresh_tracks(%{assigns: %{current_user: nil}} = socket, _id), do: socket

  defp refresh_tracks(socket, project_id) do
    if Enum.any?(socket.assigns.projects, &(&1.id == project_id)) do
      user = socket.assigns.current_user
      traced_async(socket, {:tracks, project_id}, fn -> Tracks.list(user, project_id) end)
    else
      socket
    end
  end

  # Reads only, so that it can run in a task. A project's tracks that cannot
  # be read are an empty group rather than a missing key, which is what keeps
  # the rail drawing the project.
  defp read_rail(user) do
    projects = Projects.list(user)

    tracks =
      Map.new(projects, fn p ->
        case Tracks.list(user, p.id) do
          {:ok, tracks} -> {p.id, tracks}
          _ -> {p.id, []}
        end
      end)

    {projects, tracks}
  end

  # Subscribing is this process's to do --- `Phoenix.PubSub` registers the
  # caller --- so it happens here rather than beside the reads above.
  defp apply_rail(socket, {projects, tracks}) do
    if connected?(socket) do
      old = MapSet.new(socket.assigns.projects, & &1.id)
      new = MapSet.new(projects, & &1.id)
      Enum.each(MapSet.difference(old, new), &Hub.unsubscribe/1)
      Enum.each(MapSet.difference(new, old), &Hub.subscribe/1)
    end

    assign(socket,
      projects: projects,
      tracks: tracks,
      attention: attention_count(tracks),
      expanded_projects:
        MapSet.intersection(socket.assigns.expanded_projects, MapSet.new(projects, & &1.id))
    )
  end

  defp agent_name(%Accounts.User{agent: :codex}), do: "Codex"
  defp agent_name(%Accounts.User{}), do: "Claude Code"

  defp open_dialog(socket, :new_project),
    do:
      socket
      |> assign(dialog: :new_project, project_form: Form.new(:new_project))
      |> load_repos(nil)

  defp open_dialog(socket, :new_track) do
    suggested =
      Names.name_track(Enum.map(socket.assigns.tracks[project_id(socket)] || [], & &1.title))

    assign(socket,
      dialog: :new_track,
      track_form: Form.new(:new_track, %{"title" => suggested}),
      origin_kind: :blank,
      refs: [],
      advanced_track: false
    )
  end

  defp open_dialog(socket, :search), do: assign(socket, dialog: :search, query: "")

  # The settings dialog loads and holds its own four forms, so opening it is
  # only opening it.
  defp open_dialog(socket, :settings), do: assign(socket, dialog: :settings)

  # The people dialog loads its own list, so opening it is only opening it.
  defp open_dialog(socket, :people), do: assign(socket, dialog: :people)

  # The account dialog is the agent panel, which holds its own state too.
  defp open_dialog(socket, :account), do: assign(socket, dialog: :account)

  # The repositories this person's installations can see: a GitHub call, off
  # this process for the same reason as the refs above. What is on offer is
  # cleared first, because the previous answer belongs to whichever
  # installation was selected last and offering it under a new one would let
  # somebody create a project against a repository this account cannot see.
  defp load_repos(socket, id) do
    if Accounts.capabilities().github do
      user = socket.assigns.current_user

      socket
      |> assign(repos: [], installations: [], installation: nil)
      |> traced_async(:repos, fn -> Projects.repos(user, id) end)
    else
      socket
    end
  end

  defp track_suffix(nil), do: ""
  defp track_suffix(id), do: "/t/#{id}"

  defp project_id(socket), do: socket.assigns.project && socket.assigns.project.id
  defp ref_id(ref), do: to_string(ref[:number] || ref[:name])
  defp ref_label(ref), do: if(ref[:number], do: "##{ref.number} #{ref.title}", else: ref.name)

  defp attention_count(tracks),
    do:
      Enum.reduce(tracks, 0, fn {_id, rows}, count -> count + Enum.count(rows, &attention?/1) end)

  defp attention?(track), do: track.status == :failed or (track.status == :ready and track.unread)

  defp matching?(track, project, query),
    do:
      String.contains?(
        String.downcase("#{project.name} #{track.title} #{track.branch}"),
        String.downcase(query)
      )
end
