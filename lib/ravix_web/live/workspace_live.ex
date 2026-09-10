defmodule RavixWeb.WorkspaceLive do
  @moduledoc "The project rail, inbox, navigation, and project management forms."
  use RavixWeb, :live_view

  alias Ravix.{Accounts, Hub, People, Previews, Projects, Tracks}
  alias Ravix.Tracks.Names
  alias RavixWeb.Error

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
        form_data: %{},
        people: [],
        invite: nil,
        repos: [],
        installations: [],
        installation: nil,
        refs: [],
        origin_kind: "blank",
        query: "",
        busy: false,
        settings: nil,
        preview_defaults: nil
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
      open_dialog(socket, "new-track")
    else
      socket
    end
  end

  defp validate_session(socket) do
    if socket.assigns.current_user &&
         is_nil(Accounts.session_user(Ravix.Crypto.sha256(socket.assigns.session_token))) do
      assign(socket, current_user: nil, projects: [], tracks: %{})
    else
      socket
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
      {:noreply, assign(socket, advanced_track: false, origin_kind: "blank", refs: [])}
    else
      {:noreply, assign(socket, advanced_track: true)}
    end
  end

  def handle_event("search", %{"q" => q}, socket), do: {:noreply, assign(socket, query: q)}
  def handle_event("edit", params, socket), do: {:noreply, assign(socket, form_data: params)}

  def handle_event("dialog", %{"name" => name}, socket) do
    {:noreply, open_dialog(socket, name)}
  end

  def handle_event("installation", %{"installation" => id}, socket) do
    case Integer.parse(id) do
      {id, ""} -> {:noreply, load_repos(socket, id)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("create-project", params, socket) do
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
     |> assign(busy: true, form_data: params)
     |> start_async(:create_project, fn -> Projects.create(user, attrs) end)}
  end

  def handle_event("origin", %{"kind" => kind}, socket) when kind in ~w(blank branch pr issue) do
    socket = assign(socket, origin_kind: kind, refs: [], advanced_track: true)

    if kind == "blank" do
      {:noreply, socket}
    else
      refs_kind = %{"branch" => :branches, "pr" => :pulls, "issue" => :issues}[kind]

      {:noreply,
       result(
         socket,
         Projects.refs(socket.assigns.current_user, project_id(socket), refs_kind),
         &assign(&1, refs: &2)
       )}
    end
  end

  def handle_event("create-track", params, socket) do
    kind = socket.assigns.origin_kind
    ref = Enum.find(socket.assigns.refs, &(ref_id(&1) == params["ref"]))

    origin =
      case {kind, ref} do
        {"branch", %{} = r} -> %{kind: kind, base: r.name}
        {"pr", %{} = r} -> %{kind: kind, number: r.number, title: r.title, base: r.base_ref}
        {"issue", %{} = r} -> %{kind: kind, number: r.number, title: r.title}
        _ -> %{kind: "blank"}
      end

    user = socket.assigns.current_user
    id = project_id(socket)
    attrs = %{title: params["title"], origin: origin}

    {:noreply,
     socket
     |> assign(busy: true, form_data: params)
     |> start_async(:create_track, fn -> Tracks.open(user, id, attrs) end)}
  end

  def handle_event("save-settings", params, socket) do
    attrs = Map.take(params, ~w(name runtime model instructions setup_script))

    attrs =
      Map.put(
        attrs,
        "packages",
        Map.new(~w(apt pip npm), fn key ->
          {key, String.split(params[key] || "", ~r/[\s,]+/, trim: true)}
        end)
      )

    {:noreply,
     result(
       socket,
       Projects.update_settings(socket.assigns.current_user, project_id(socket), attrs),
       fn s, _ ->
         s
         |> reload()
         |> open_dialog("settings")
         |> put_flash(
           :info,
           "Settings saved. Open a new track to use updated instructions and secrets."
         )
       end
     )}
  end

  def handle_event("save-secret", params, socket) do
    {:noreply,
     result(
       socket,
       Projects.update_settings(socket.assigns.current_user, project_id(socket), %{
         secret: Map.take(params, ~w(store key value))
       }),
       fn s, _ ->
         s |> open_dialog("settings") |> put_flash(:info, "Secret updated.")
       end
     )}
  end

  def handle_event("save-preview-defaults", params, socket) do
    config =
      if params["clear"] == "true",
        do: nil,
        else: Map.take(params, ~w(directory command readiness_path))

    {:noreply,
     result(
       socket,
       Previews.set_defaults(socket.assigns.current_user, project_id(socket), config),
       fn s, defaults ->
         s |> assign(preview_defaults: defaults) |> put_flash(:info, "Preview defaults saved.")
       end
     )}
  end

  def handle_event("project-danger", %{"action" => action, "confirm" => name}, socket)
      when action in ~w(rebuild delete) do
    if socket.assigns.project && name == socket.assigns.project.name do
      user = socket.assigns.current_user
      id = project_id(socket)

      {:noreply,
       socket
       |> assign(busy: true)
       |> start_async(:project_danger, fn ->
         if action == "rebuild", do: Projects.rebuild(user, id), else: Projects.destroy(user, id)
       end)}
    else
      {:noreply, put_flash(socket, :error, "Type the project name to confirm.")}
    end
  end

  def handle_event("invite-person", %{"login" => login}, socket) do
    {:noreply,
     result(
       socket,
       People.add_project(socket.assigns.current_user, project_id(socket), login),
       &assign(&1, people: &2)
     )}
  end

  def handle_event("remove-person", %{"login" => login}, socket) do
    {:noreply,
     result(
       socket,
       People.remove_project(socket.assigns.current_user, project_id(socket), login),
       fn s, _ ->
         s |> reload() |> push_patch(to: "/")
       end
     )}
  end

  def handle_event("invite-link", %{"action" => action}, socket) do
    user = socket.assigns.current_user
    id = project_id(socket)

    response =
      if action == "create",
        do: People.mint_project_link(user, id),
        else: People.drop_project_link(user, id)

    {:noreply,
     result(socket, response, fn s, value ->
       assign(s, invite: if(action == "create", do: value, else: nil))
     end)}
  end

  @impl true
  def handle_async(:create_project, {:ok, response}, socket) do
    {:noreply,
     result(assign(socket, busy: false), response, fn s, p ->
       s |> reload() |> push_patch(to: "/p/#{p.id}")
     end)}
  end

  def handle_async(:create_track, {:ok, response}, socket) do
    {:noreply,
     result(assign(socket, busy: false), response, fn s, t ->
       s |> reload() |> push_patch(to: "/p/#{t.project_id}/t/#{t.id}")
     end)}
  end

  def handle_async(:project_danger, {:ok, response}, socket) do
    {:noreply,
     result(assign(socket, busy: false), response, fn s, _ ->
       s |> reload() |> push_patch(to: "/")
     end)}
  end

  def handle_async(_name, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(busy: false)
       |> put_flash(:error, "The operation could not finish. Refresh and try again.")}

  @impl true
  def handle_info({:hub, %{event: "here"}}, socket), do: {:noreply, socket}

  def handle_info({:hub, _event}, socket) do
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

  defp open_dialog(socket, "new-project"),
    do: socket |> assign(dialog: "new-project", form_data: %{}) |> load_repos(nil)

  defp open_dialog(socket, "new-track"),
    do:
      assign(socket,
        dialog: "new-track",
        form_data: %{
          "title" =>
            Names.name_track(
              Enum.map(socket.assigns.tracks[project_id(socket)] || [], & &1.title)
            )
        },
        origin_kind: "blank",
        refs: [],
        advanced_track: false
      )

  defp open_dialog(socket, "search"), do: assign(socket, dialog: "search", query: "")

  defp open_dialog(socket, "settings") do
    result(socket, Projects.settings(socket.assigns.current_user, project_id(socket)), fn s,
                                                                                          settings ->
      defaults =
        case Previews.defaults(s.assigns.current_user, project_id(s)) do
          {:ok, d} -> d
          _ -> nil
        end

      assign(s, dialog: "settings", settings: settings, preview_defaults: defaults)
    end)
  end

  defp open_dialog(socket, "people") do
    result(
      socket,
      People.list_project(socket.assigns.current_user, project_id(socket)),
      &assign(&1, dialog: "people", people: &2, invite: nil)
    )
  end

  defp open_dialog(socket, _), do: socket

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

  defp result(socket, :ok, fun), do: fun.(socket, nil)
  defp result(socket, {:ok, value}, fun), do: fun.(socket, value)

  defp result(socket, {:error, reason}, _fun),
    do: put_flash(socket, :error, Error.from(reason).message)

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

  defp invitation_url(%{url: url}), do: url
  defp invitation_url(%{link: link}), do: invitation_url(link)
  defp invitation_url(_), do: nil
end
