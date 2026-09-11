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

  # The five dialogs, as the buttons spell them and as this module does.
  @dialogs %{
    "search" => :search,
    "new-project" => :new_project,
    "new-track" => :new_track,
    "settings" => :settings,
    "people" => :people
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
        expanded_projects: MapSet.new(),
        advanced_track: false,
        project: nil,
        track_id: nil,
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
  defp wrong_page(%{assigns: %{current_user: nil, live_action: :login}}), do: nil
  defp wrong_page(%{assigns: %{current_user: nil}}), do: "/login"
  defp wrong_page(%{assigns: %{live_action: :login}}), do: "/"
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
      assign(socket,
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
      :error -> assign(socket, current_user: nil, projects: [], tracks: %{})
    end
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, reload(socket)}

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
     |> start_async(:create_project, fn -> Projects.create(user, attrs) end)}
  end

  def handle_event("origin", %{"kind" => word}, socket) when is_map_key(@form_origins, word) do
    kind = Map.fetch!(@form_origins, word)
    socket = assign(socket, origin_kind: kind, refs: [], advanced_track: true)

    case @origin_refs[kind] do
      nil ->
        {:noreply, socket}

      refs_kind ->
        {:noreply,
         result(
           socket,
           Projects.refs(socket.assigns.current_user, project_id(socket), refs_kind),
           &assign(&1, refs: &2)
         )}
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
     |> start_async(:create_track, fn -> Tracks.open(user, id, attrs) end)}
  end

  @impl true
  def handle_async(:create_project, {:ok, response}, socket) do
    {:noreply,
     result(
       assign(socket, busy: false),
       response,
       fn s, p -> s |> reload() |> push_patch(to: "/p/#{p.id}") end,
       :project_form
     )}
  end

  def handle_async(:create_track, {:ok, response}, socket) do
    {:noreply,
     result(
       assign(socket, busy: false),
       response,
       fn s, t -> s |> reload() |> push_patch(to: "/p/#{t.project_id}/t/#{t.id}") end,
       :track_form
     )}
  end

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
  # Everything else reloads. A narrower rule here would have to know which
  # of the rail's fields each event can reach, and getting that wrong shows
  # up as a status dot that is quietly a minute stale.
  @impl true
  # The people dialog did the removal. Either way the rail is now wrong --
  # a project you just left goes, and a project you took somebody off has a
  # different set of tracks under it -- so it is re-read and the dialog
  # closes behind it.
  def handle_info({:person_removed, :project, _login}, socket),
    do: {:noreply, socket |> reload() |> push_patch(to: "/")}

  # A `live_component` cannot put a flash in the page's own socket, so it
  # sends the sentence here; see `RavixWeb.Live.Result.error/2`.
  def handle_info({:flash, kind, message}, socket),
    do: {:noreply, put_flash(socket, kind, message)}

  # The settings dialog saved a project's settings, which may have renamed
  # it. The rail on the left is showing the old name until it is re-read.
  def handle_info(:project_settings_saved, socket), do: {:noreply, reload(socket)}

  # A rebuild closed every track on the project and a delete removed it
  # outright. Either way this is no longer somewhere to be, and a component
  # cannot patch the URL.
  def handle_info(:project_left_behind, socket),
    do: {:noreply, socket |> reload() |> push_patch(to: "/")}

  def handle_info({:hub, %Event{name: name}}, socket) when name in [:here, :queue],
    do: {:noreply, socket}

  def handle_info({:hub, %Event{}}, socket) do
    socket = reload(socket)

    if socket.assigns.project &&
         not Enum.any?(socket.assigns.projects, &(&1.id == socket.assigns.project.id)) do
      {:noreply, push_patch(socket, to: "/")}
    else
      {:noreply, socket}
    end
  end

  defp reload(%{assigns: %{current_user: nil}} = socket), do: socket

  defp reload(socket) do
    projects = Projects.list(socket.assigns.current_user)

    if connected?(socket) do
      old = MapSet.new(socket.assigns.projects, & &1.id)
      new = MapSet.new(projects, & &1.id)
      Enum.each(MapSet.difference(old, new), &Hub.unsubscribe/1)
      Enum.each(MapSet.difference(new, old), &Hub.subscribe/1)
    end

    tracks =
      Map.new(projects, fn p ->
        case Tracks.list(socket.assigns.current_user, p.id) do
          {:ok, tracks} -> {p.id, tracks}
          _ -> {p.id, []}
        end
      end)

    assign(socket,
      projects: projects,
      tracks: tracks,
      expanded_projects:
        MapSet.intersection(socket.assigns.expanded_projects, MapSet.new(projects, & &1.id))
    )
  end

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

  defp load_repos(socket, id) do
    if Accounts.capabilities().github do
      result(socket, Projects.repos(socket.assigns.current_user, id), fn s, data ->
        assign(s,
          repos: data.repos,
          installations: data.installations,
          installation: data.selected
        )
      end)
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
