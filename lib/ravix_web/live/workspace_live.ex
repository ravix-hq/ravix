defmodule RavixWeb.WorkspaceLive do
  @moduledoc "The project rail, inbox, navigation, and project management forms."
  use RavixWeb, :live_view

  alias RavixWeb.Live.NewProject

  alias Ravix.{Accounts, Hub, Ids, People, Projects, Schedules, Tracks, Workspaces}
  alias Ravix.Accounts.Access
  alias Ravix.Hub.Event
  alias Ravix.Projects.Sections
  alias Ravix.Tracks.MachineState
  alias Ravix.Workspaces.{Picker, Repositories}
  alias RavixWeb.Live.Form
  alias RavixWeb.Live.Guard
  alias RavixWeb.Live.ThreadConnect
  alias RavixWeb.Live.WorkspaceSwitcher

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
  @origin_kinds Ravix.Tracks.Track.origin_kinds() -- [:plan]
  @form_origins Map.new(@origin_kinds, &{to_string(&1), &1})
  @origin_labels %{blank: "Blank", branch: "Branch", pr: "Pull request", issue: "Issue"}
  @origin_refs %{branch: :branches, pr: :pulls, issue: :issues}

  # The workspace dialogs, as the buttons spell them and as this module does.
  @dialogs %{
    "sections" => :sections,
    "search" => :search,
    "new-project" => :new_project,
    "new-track" => :new_track,
    "settings" => :settings,
    "people" => :people,
    "account" => :account,
    "help" => :help,
    "changes" => :changes
  }

  @doc "The origin buttons on the new-track form, in the order they are offered."
  @spec origin_choices() :: [{Ravix.Tracks.Track.origin_kind(), String.t()}]
  def origin_choices, do: Enum.map(@origin_kinds, &{&1, @origin_labels[&1]})

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user]
    workspaces = WorkspaceSwitcher.list(user)

    socket =
      assign(socket,
        session_token: session["session_token"],
        # The viewer's IANA zone from the browser's connect params: what a new
        # schedule is prefilled with and schedule times are shown in. UTC
        # before the socket connects, or when the browser names no known zone.
        timezone: Schedules.timezone((get_connect_params(socket) || %{})["timezone"]),
        github_available: Accounts.capabilities().github,
        reconnect_agent: nil,
        health_refresh: 0,
        # What the page shows: the projects and tracks of the current
        # workspace (ADR 0009), or all of them while RAVIX_WORKSPACE_ACCESS
        # is off. The sidebar, quick-jump, badges, the Inbox and New track all
        # read these. See `scope_rail/2`.
        projects: [],
        # Everything the viewer reaches, across workspaces: what the scope is
        # cut from, what desktop notifications and the Inbox's "in other
        # workspaces" count read, and what a `/p/:id` link may switch to.
        all_projects: [],
        all_tracks: %{},
        all_notices: [],
        # The current workspace (`Ravix.Workspaces.current/2`), nil unscoped;
        # the legacy projects shared with the viewer, drawn as "Shared with
        # you" in their personal workspace; and the Inbox items elsewhere.
        # Resolved here, the way every rail read resolves it (`scope_rail/2`),
        # so the disconnected render names the same workspace as the
        # connected one rather than the switcher's first entry (RAV-67).
        current_workspace: current_workspace(user, workspaces),
        watched_workspace: nil,
        # A project a URL named before the rail arrived, for that rail to
        # follow into its workspace; see `open_url/2`.
        url_project: nil,
        shared_ids: MapSet.new(),
        other_attention: 0,
        rail_loaded: false,
        rail_error: false,
        rail_retried: false,
        pending_url: nil,
        url_notice: nil,
        sections: [],
        section_placements: %{},
        tracks: %{},
        # Closed tracks of the projects this person asked to see them for:
        # listed, never counted, never a URL to open.
        closed_tracks: %{},
        closed_projects: MapSet.new(),
        # How many pages of closed tracks each shown project lists; see
        # `closed_limits/3`. Held per page view, not persisted.
        closed_pages: %{},
        reopen: nil,
        track_errors: MapSet.new(),
        track_loading: MapSet.new(),
        # How many tracks across every project want somebody. Counted where
        # the rail is read rather than in the template, which asked for it
        # four times a render --- twice in the sidebar badge and twice in the
        # inbox heading --- and each ask walked every track of every project.
        attention: 0,
        # People who lost access to this person's tracks when invite links
        # were retired (ADR 0009 phase 5); Inbox rows, counted in `attention`.
        access_notices: [],
        noticed: nil,
        notice_thread: nil,
        advanced_track: false,
        project: nil,
        selected_plan_id: nil,
        new_plan: false,
        track_id: nil,
        # The nested `RavixWeb.TrackLive`, once it has said where it is. See
        # the `:track_host` clause of `handle_info/2`, and `hand_over/4`.
        track_host: nil,
        # Whether the yard is open over the page. Only the phone layout asks:
        # under `--bp-narrow` the rail is gone and the "Menu" button in the
        # mobile nav is what brings it back. Held here rather than in the
        # browser so a patch --- which is what every link in the yard does
        # --- finds it and closes it; see `handle_params/3`.
        yard_open: false,
        dialog: nil,
        changes: [],
        changes_unseen: 0,
        project_form: Form.new(:new_project),
        project_generation: 0,
        project_agents: nil,
        project_agent_error: nil,
        project_mode: "github",
        track_form: Form.new(:new_track),
        track_options: nil,
        track_project: nil,
        thread_connect: nil,
        repos_loading: false,
        refs_loading: false,
        repos: [],
        installations: [],
        installation: nil,
        refs: [],
        origin_kind: :blank,
        query: "",
        # Plan titles quick-jump offers, read when the dialog opens. Only
        # projects this person may enter whole contribute; see `Plans.titles/1`.
        search_plans: [],
        # Creating a project and creating a track, and nothing else. The
        # settings dialog owns its own; see `RavixWeb.Live.SettingsDialog`
        # for why one flag for the whole page could not answer "may I press
        # this".
        busy: false,
        # The sidebar's workspace switcher; empty while RAVIX_WORKSPACE_ACCESS
        # is off, which draws nothing. See `RavixWeb.Live.WorkspaceSwitcher`.
        workspaces: workspaces,
        # The New track repository list (RAV-10) while RAVIX_WORKSPACE_ACCESS
        # is on; nil draws today's project select. See `Ravix.Workspaces.Picker`.
        picker: nil,
        # Scratch projects in their own rail group, with the same switch.
        scratch_group: Workspaces.enabled?()
      )

    {:ok, if(socket.assigns.current_user, do: socket |> unseen() |> reload_async(), else: socket)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    # Every link in the yard patches, so arriving anywhere is leaving it.
    socket =
      socket
      |> validate_session()
      |> navigation_notice(URI.parse(uri).path)
      |> assign(yard_open: false, pending_url: nil)

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

  defp wrong_page(%{assigns: %{rail_loaded: false}}), do: nil

  defp wrong_page(%{assigns: %{live_action: action} = assigns})
       when action in [:home, :projects, :inbox] do
    if Accounts.needs_onboarding?(assigns.current_user, length(assigns.all_projects)),
      do: "/welcome"
  end

  defp wrong_page(_socket), do: nil

  # Before the rail arrives, database-backed access is enough to mount the
  # selected child. An unavailable URL waits for the rail's normal decision.
  # The project the URL named is remembered for that rail, which scopes the
  # page to its workspace (`scope_rail/2`).
  defp open_url(%{assigns: %{rail_loaded: false}} = socket, %{"project" => id} = params) do
    user = socket.assigns.current_user

    with {:ok, project} <- Projects.get(user, id),
         {:ok, track} <- requested_track(user, id, params["track"]) do
      socket
      |> assign(url_project: project.id)
      |> await_follow(project)
      |> select_project(project, params["track"], params, track)
    else
      _ -> assign(socket, pending_url: params)
    end
  end

  defp open_url(socket, params) do
    socket = socket |> recheck_rail() |> follow(params["project"])

    project = Enum.find(socket.assigns.projects, &(&1.id == params["project"]))
    track_id = params["track"]

    valid_track =
      is_nil(track_id) or
        Enum.any?(socket.assigns.tracks[params["project"]] || [], &(&1.id == track_id))

    cond do
      params["project"] && is_nil(project) ->
        bad_url(socket, "/home", missing_message(params["project"], :project))

      project && not valid_track ->
        bad_url(socket, "/p/#{project.id}", missing_message(track_id, :track))

      true ->
        select_project(socket, project, track_id, params)
    end
  end

  # A URL naming a project in another of the viewer's workspaces moves the
  # page there once the rail arrives (`scope_rail/2`). Until then the
  # switcher draws a skeleton rather than naming the workspace about to be left.
  defp await_follow(%{assigns: %{current_workspace: %{workspace: %{id: id}}}} = socket, project) do
    home = Workspaces.home(socket.assigns.current_user, socket.assigns.workspaces, project)
    if home in [nil, id], do: socket, else: assign(socket, current_workspace: nil)
  end

  defp await_follow(socket, _project), do: socket

  defp missing_message(id, kind) do
    case {Ecto.UUID.cast(id), kind} do
      {:error, :project} -> "Invalid project link."
      {:error, :track} -> "Invalid track link."
      {_, :project} -> "Project not found."
      {_, :track} -> "Track not found in this project."
    end
  end

  # Show the notice on the corrective patch, then clear just this notice on
  # the next navigation. Unrelated operation errors keep their own lifecycle.
  defp bad_url(socket, target, message) do
    socket |> assign(url_notice: {:pending, target, message}) |> push_patch(to: target)
  end

  defp navigation_notice(%{assigns: %{url_notice: {:pending, target, message}}} = socket, target),
    do: socket |> flash(:info, message) |> assign(url_notice: {:shown, message})

  defp navigation_notice(%{assigns: %{url_notice: {:shown, message}}} = socket, _path),
    do: socket |> clear_notice(:info, message) |> assign(url_notice: nil)

  defp navigation_notice(socket, _path), do: assign(socket, url_notice: nil)

  defp requested_track(_user, _project_id, nil), do: {:ok, nil}

  defp requested_track(user, project_id, id) do
    case Access.track_access(user, id) do
      {:ok, %{track: %{project_id: ^project_id, closed_at: nil} = track}} ->
        {:ok, Tracks.present(track)}

      _ ->
        {:error, :not_found}
    end
  end

  defp select_project(socket, project, track_id, params, track \\ nil) do
    socket =
      socket
      |> hand_over(project, track_id, track)
      |> url_thread(track_id, params)
      |> select_notice_thread(track_id)
      |> assign(
        project: project,
        selected_plan_id: if(params["new"] != "plan", do: params["plan"]),
        new_plan: params["new"] == "plan",
        track_id: track_id,
        dialog: nil
      )

    socket = assign_page_title(socket, track)

    cond do
      params["new"] == "track" && project && project.access != :tracks ->
        open_dialog(socket, :new_track)

      params["settings"] == "true" && project && project.role == :owner ->
        open_dialog(socket, :settings)

      true ->
        socket
    end
  end

  defp url_thread(socket, track_id, %{"thread" => thread_id}) when is_binary(track_id),
    do: assign(socket, notice_thread: {track_id, thread_id})

  defp url_thread(socket, _track_id, _params), do: socket

  defp inbox_path(project, track) do
    thread =
      Enum.find(track.threads, &Map.get(&1, :mention)) ||
        Enum.find(track.threads, &(&1.unread && attention?(&1))) ||
        Enum.find(track.threads, &attention?/1)

    thread_id = if thread, do: thread.id, else: track.id
    "/p/#{project.id}/t/#{track.id}?thread=#{thread_id}"
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
  defp hand_over(socket, project, track_id, requested) do
    track =
      project && track_id &&
        (requested || Enum.find(socket.assigns.tracks[project.id] || [], &(&1.id == track_id)))

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
    case Guard.verify(socket.assigns[:session_guard], socket.assigns.session_hash) do
      {:ok, guard} ->
        assign(socket, session_guard: guard)

      :error ->
        assign(socket,
          current_user: nil,
          projects: [],
          tracks: %{},
          all_projects: [],
          all_tracks: %{},
          attention: 0,
          other_attention: 0
        )
    end
  end

  # A desktop notification was clicked. The browser asks rather than going
  # there itself, so the track and thread it names are checked afresh here,
  # and `handle_params/3` checks the URL again on the way in. A notification
  # shown by a bundle from before threads names no thread and means the
  # track's default one; anything that is not an id is nowhere to go.
  @impl true
  def handle_event("open-notice", %{"track" => id} = params, socket) do
    thread_id = if is_binary(params["thread"]), do: params["thread"], else: id

    case Ravix.Accounts.Access.thread_access(socket.assigns.current_user, id, thread_id) do
      {:ok, %{project: project, track: %{closed_at: nil}, thread: %{closed_at: nil}}} ->
        {:noreply,
         socket
         |> assign(notice_thread: {id, thread_id})
         |> push_patch(to: "/p/#{project.id}/t/#{id}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("refresh", _, socket), do: {:noreply, reload_async(socket, fresh: true)}

  def handle_event("dismiss-access-notice", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    {:noreply,
     result(socket, People.dismiss_notice(user, id), fn s, _ ->
       s
       |> update(:all_notices, fn notices -> Enum.reject(notices, &(&1.id == id)) end)
       |> derive_scope()
     end)}
  end

  def handle_event("workspace-create", %{"name" => name}, socket),
    do: {:noreply, WorkspaceSwitcher.create(socket, name)}

  # The switcher makes a workspace current and the page shows it: the rail
  # already holds every workspace's projects and tracks, so it is scoped
  # again from those, with membership and visibility re-read and no provider
  # asked. A project left open from the workspace being left is closed, for
  # the new workspace's home; closed first, or one whose settings are open
  # would be followed straight back (`scope_rail/2`).
  def handle_event("workspace-select", %{"workspace" => id}, socket) do
    case WorkspaceSwitcher.select(socket, id) do
      {:ok, socket} ->
        open = socket.assigns.project
        socket = socket |> assign(project: nil) |> recheck_rail()

        {:noreply,
         case open && Enum.find(socket.assigns.projects, &(&1.id == open.id)) do
           nil when is_nil(open) -> socket
           nil -> push_patch(socket, to: "/home")
           project -> assign(socket, project: project)
         end}

      {:error, socket} ->
        {:noreply, recheck_rail(socket)}
    end
  end

  # Without a project; with one, a dialog closes by patching (`dismiss/2`).
  def handle_event("dismiss", _, socket), do: {:noreply, assign(socket, dialog: nil)}

  def handle_event("dismiss-switcher", _, socket), do: {:noreply, assign(socket, dialog: nil)}

  def handle_event("yard", _, socket),
    do: {:noreply, assign(socket, yard_open: !socket.assigns.yard_open)}

  # An Escape that closed a dialog over the yard closes only the dialog
  # (`assets/js/dialog_escape.js`).
  def handle_event("yard-close", %{"dialog" => true}, socket), do: {:noreply, socket}
  def handle_event("yard-close", _, socket), do: {:noreply, assign(socket, yard_open: false)}

  def handle_event("create-section", %{"section" => attrs}, socket) do
    section_result(socket, Sections.create(socket.assigns.current_user, attrs))
  end

  def handle_event("rename-section", %{"section_id" => id, "section" => attrs}, socket) do
    section_result(
      socket,
      Sections.update(socket.assigns.current_user, id, Map.take(attrs, ["name"]))
    )
  end

  def handle_event("retry-tracks", %{"id" => id}, socket) do
    if MapSet.member?(socket.assigns.track_loading, id),
      do: {:noreply, socket},
      else: {:noreply, socket |> recheck_rail() |> refresh_tracks(id)}
  end

  def handle_event("toggle-section", %{"id" => id, "collapsed" => collapsed}, socket) do
    section_result(
      socket,
      Sections.update(socket.assigns.current_user, id, %{collapsed: collapsed})
    )
  end

  def handle_event("rail-scope", %{"scope" => scope}, socket) do
    case Accounts.put_rail_scope(socket.assigns.current_user, scope) do
      {:ok, user} ->
        {:noreply, assign(socket, current_user: user)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, RavixWeb.Error.from(reason).message)}
    end
  end

  def handle_event("show-closed", %{"project" => id, "show" => show}, socket) do
    show? = show == "true"

    case Sections.show_closed(socket.assigns.current_user, id, show?) do
      {:ok, _} ->
        socket = update(socket, :closed_projects, &toggle(&1, id, show?))

        {:noreply,
         if(show?,
           do: refresh_tracks(socket, id),
           else:
             socket
             |> update(:closed_tracks, &Map.delete(&1, id))
             |> update(:closed_pages, &Map.delete(&1, id))
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, RavixWeb.Error.from(reason).message)}
    end
  end

  # Reopening is a new track from the closed one's branch: closing removed
  # the worktree and ended the conversation, so there is nothing to resume.
  def handle_event("reopen-track", %{"track" => id}, socket) do
    socket = recheck_rail(socket)

    found =
      Enum.find_value(socket.assigns.closed_tracks, fn {project_id, rows} ->
        track = Enum.find(rows, &(&1.id == id))
        project = track && Enum.find(socket.assigns.projects, &(&1.id == project_id))
        if project && reopenable?(project), do: {project, track}
      end)

    case found do
      {project, track} ->
        visibility =
          if track.visibility == :private and
               Ravix.Config.dedicated_opens_enabled?(socket.assigns.current_user),
             do: "private",
             else: "project"

        {:noreply,
         socket
         |> new_track_dialog(project)
         |> assign(
           reopen: %{title: track.title, branch: track.branch},
           track_form: Form.new(:new_track, %{"ref" => track.branch, "visibility" => visibility})
         )
         |> choose_origin(:branch)}

      nil ->
        {:noreply, flash(socket, :error, "Track not available.")}
    end
  end

  def handle_event("closed-older", %{"project" => id}, socket) do
    if MapSet.member?(socket.assigns.closed_projects, id),
      do:
        {:noreply,
         socket
         |> update(:closed_pages, &Map.update(&1, id, 2, fn n -> n + 1 end))
         |> refresh_tracks(id)},
      else: {:noreply, socket}
  end

  def handle_event("delete-section", %{"id" => id}, socket) do
    section_result(socket, Sections.delete(socket.assigns.current_user, id))
  end

  def handle_event("move-project", %{"project" => id, "section" => section_id}, socket) do
    section_result(socket, Sections.move(socket.assigns.current_user, id, section_id))
  end

  def handle_event("top-new-track", _, socket) do
    socket = recheck_rail(socket)
    project = socket.assigns.project

    if Workspaces.enabled?() do
      anchor = if project && project.access != :tracks, do: project
      {:noreply, picker_dialog(socket, anchor)}
    else
      {:noreply, top_new_track(socket, project)}
    end
  end

  # ── the New track repository list (RAV-10) ────────────────────────────

  def handle_event("picker-filter", %{"q" => q}, %{assigns: %{picker: %Picker{}}} = socket),
    do: {:noreply, update(socket, :picker, &%{&1 | query: String.slice(to_string(q), 0, 200)})}

  def handle_event("picker-pick", %{"project" => id}, %{assigns: %{picker: %Picker{}}} = socket) do
    picker = socket.assigns.picker
    listed = Enum.map(picker.entries, & &1.project) ++ picker.scratch

    case Enum.find(listed, &(&1.id == id)) do
      _ when socket.assigns.busy -> {:noreply, socket}
      nil -> {:noreply, flash(socket, :error, "Project not available.")}
      project -> {:noreply, choose_track_project(socket, project)}
    end
  end

  # Enter in the query without the browser hook: the first match for what
  # was typed.
  def handle_event("picker-submit", params, %{assigns: %{picker: %Picker{} = picker}} = socket) do
    picker = if is_binary(params["q"]), do: %{picker | query: params["q"]}, else: picker
    socket = assign(socket, picker: picker)

    case Picker.matches(picker) do
      [%{project: project} | _] -> handle_event("picker-pick", %{"project" => project.id}, socket)
      [] -> {:noreply, socket}
    end
  end

  def handle_event("picker-scratch", _params, %{assigns: %{picker: %Picker{}}} = socket) do
    case socket.assigns.picker.scratch do
      [project | _] ->
        handle_event("picker-pick", %{"project" => project.id}, socket)

      [] ->
        {:noreply,
         socket
         |> assign(picker: nil)
         |> open_dialog(:new_project)
         |> assign(project_mode: "scratch")}
    end
  end

  def handle_event(
        "picker-add-open",
        _params,
        %{assigns: %{picker: %Picker{can_add: true}}} = socket
      ) do
    picker = Picker.load_addable(socket.assigns.picker, socket.assigns.current_user)
    {:noreply, assign(socket, picker: %{picker | mode: :add, query: ""})}
  end

  def handle_event("picker-add-back", _params, %{assigns: %{picker: %Picker{}}} = socket),
    do: {:noreply, update(socket, :picker, &%{&1 | mode: :repos, query: ""})}

  def handle_event(
        "picker-add",
        %{"repo" => repo},
        %{assigns: %{picker: %Picker{can_add: true, adding: nil, workspace: workspace}}} = socket
      ) do
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> update(:picker, &%{&1 | adding: repo})
     |> start_async(:picker_add, fn -> Repositories.add(user, workspace.id, repo) end)}
  end

  def handle_event("picker-" <> _, _params, socket), do: {:noreply, socket}

  # While the repository list is shown, the old select's event is only
  # another way to pick from it, never around it.
  def handle_event(
        "new-track-project",
        %{"project" => id},
        %{assigns: %{picker: %Picker{}}} = socket
      ),
      do: handle_event("picker-pick", %{"project" => id}, socket)

  def handle_event("new-track-project", %{"project" => id}, socket) do
    socket = recheck_rail(socket)
    project = Enum.find(socket.assigns.projects, &(&1.id == id && &1.access != :tracks))

    cond do
      is_nil(project) || socket.assigns.dialog != :new_track || socket.assigns.busy ->
        {:noreply, flash(socket, :error, "Project not available.")}

      id == track_project_id(socket) ->
        {:noreply, socket}

      true ->
        {:noreply, choose_track_project(socket, project)}
    end
  end

  def handle_event("project-settings", %{"project" => id}, socket) do
    socket = recheck_rail(socket)
    project = Enum.find(socket.assigns.projects, &(&1.id == id))

    if project && project.access != :tracks && project.role == :owner do
      suffix = if id == project_id(socket), do: track_suffix(socket.assigns.track_id), else: ""
      {:noreply, push_patch(socket, to: "/p/#{id}#{suffix}?settings=true")}
    else
      {:noreply, flash(socket, :error, "Project not available.")}
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

  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, socket |> recheck_rail() |> assign(query: q)}

  def handle_event("choose-project-agent", %{"agent" => agent}, socket),
    do: {:noreply, NewProject.choose(socket, agent)}

  def handle_event("refresh-project-agents", _, socket),
    do: {:noreply, NewProject.refresh(socket)}

  def handle_event("edit", %{"new_project" => params}, socket),
    do: {:noreply, NewProject.edit(socket, params)}

  def handle_event("connect-thread-agent", %{"runtime" => runtime}, socket) do
    connection =
      if socket.assigns.dialog == :new_track,
        do:
          ThreadConnect.open(
            socket.assigns.current_user,
            track_project_id(socket),
            runtime,
            socket.assigns.track_options
          )

    {:noreply, assign(socket, thread_connect: connection)}
  end

  def handle_event("edit", %{"new_track" => params} = event, socket) do
    params =
      if event["_target"] in [["new_track", "runtime"], ["new_track", "model"]],
        do: Map.put(params, "preference_explicit", "true"),
        else: params

    params =
      if params["runtime"] != socket.assigns.track_form.params["runtime"],
        do: Map.delete(params, "model"),
        else: params

    {:noreply, assign(socket, track_form: Form.new(:new_track, params))}
  end

  def handle_event("dialog", %{"name" => name} = params, socket)
      when is_map_key(@dialogs, name) do
    dialog = Map.fetch!(@dialogs, name)
    socket = open_dialog(socket, dialog)

    socket =
      if dialog == :new_project,
        do:
          assign(socket,
            project_mode: if(params["mode"] == "scratch", do: "scratch", else: "github")
          ),
        else: socket

    if dialog == :changes, do: {:noreply, mark_changes(socket)}, else: {:noreply, socket}
  end

  def handle_event("mark-changes-seen", _, socket), do: {:noreply, mark_changes(socket)}

  def handle_event("installation", %{"installation" => id}, socket) do
    case Integer.parse(id) do
      {id, ""} -> {:noreply, load_repos(socket, id)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("create-project", %{"new_project" => params}, socket) do
    {:noreply,
     NewProject.create(socket, params, fn user, attrs ->
       created(Projects.create(user, attrs), user)
     end)}
  end

  def handle_event("origin", %{"kind" => word}, socket) when is_map_key(@form_origins, word),
    do: {:noreply, choose_origin(socket, Map.fetch!(@form_origins, word))}

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
        {:pr, %{} = r} -> %{kind: word, number: r.number, title: r.title, base: r.head_ref}
        {:issue, %{} = r} -> %{kind: word, number: r.number, title: r.title}
        _ -> %{kind: "blank"}
      end

    user = socket.assigns.current_user
    id = track_project_id(socket)

    attrs = %{
      title: params["title"],
      visibility: params["visibility"] || "project",
      origin: origin,
      runtime: params["runtime"],
      model: params["model"]
    }

    prompt = params["prompt"] || ""

    {:noreply,
     socket
     |> assign(busy: true, track_form: Form.new(:new_track, params))
     |> traced_async(:create_track, fn ->
       created(open_track(user, id, attrs, prompt), user)
     end)}
  end

  @impl true
  def handle_async({:track_options, id}, {:ok, {:ok, options}}, socket) do
    if id == track_project_id(socket) and socket.assigns.dialog == :new_track and
         match?({:ok, _}, Access.project_access(socket.assigns.current_user, id)),
       do:
         {:noreply,
          assign(socket,
            track_options: options,
            track_form:
              Form.new(
                :new_track,
                Map.put_new(socket.assigns.track_form.params, "runtime", options.runtime)
              )
          )},
       else: {:noreply, socket}
  end

  def handle_async({:track_options, id}, {:ok, {:error, reason}}, socket) do
    if id == track_project_id(socket) && socket.assigns.dialog == :new_track,
      do: {:noreply, put_flash(socket, :error, RavixWeb.Error.from(reason).message)},
      else: {:noreply, socket}
  end

  # The add flow's answer: the repository's project, new or the one the
  # workspace already had, becomes the selected repository. The rail is read
  # again so it lists a new project too.
  def handle_async(:picker_add, {:ok, {:ok, %{project: %{id: id}}}}, socket) do
    user = socket.assigns.current_user

    # The rail's own database read: the new project, as the caller reaches it,
    # in the current workspace it was added to.
    socket = recheck_rail(socket)
    views = socket.assigns.projects

    with %Picker{} <- socket.assigns.picker,
         true <- socket.assigns.dialog == :new_track,
         %{} = view <- Enum.find(views, &(&1.id == id && &1.access != :tracks)) do
      picker = Picker.build(user, views, view, socket.assigns.current_workspace)

      {:noreply,
       socket
       |> assign(picker: %{picker | query: "", mode: :repos})
       |> choose_track_project(view)}
    else
      _ -> {:noreply, update_picker_adding(socket)}
    end
  end

  def handle_async(:picker_add, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> update_picker_adding()
     |> put_flash(:error, RavixWeb.Error.from(reason, noun: "repository").message)}
  end

  def handle_async(:picker_add, _other, socket) do
    {:noreply,
     socket
     |> update_picker_adding()
     |> put_flash(:error, "The repository could not be added. Try again.")}
  end

  def handle_async(:project_agents, {:ok, response}, socket),
    do: {:noreply, NewProject.availability(socket, response)}

  def handle_async(:project_agents, {:exit, {:shutdown, :cancel}}, socket),
    do: {:noreply, socket}

  def handle_async(:project_agents, {:exit, reason}, socket),
    do: {:noreply, NewProject.availability(socket, {:error, {:async_exit, reason}})}

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
       fn s, {{t, queued}, rail} ->
         s
         |> apply_rail(rail)
         |> first_prompt_refused(queued)
         |> push_patch(to: "/p/#{t.project_id}/t/#{t.id}")
       end,
       :track_form
     )}
  end

  def handle_async(:agent_disconnect_notice, {:ok, message}, socket),
    do: {:noreply, flash(socket, :info, message)}

  def handle_async(:refs, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:refs, {:ok, response}, socket),
    do: {:noreply, result(assign(socket, refs_loading: false), response, &assign(&1, refs: &2))}

  def handle_async(:repos, {:ok, response}, socket) do
    {:noreply,
     result(assign(socket, repos_loading: false), response, fn s, data ->
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
    socket = finish_track_load(socket, id)

    if Enum.any?(socket.assigns.all_projects, &(&1.id == id)) do
      tracks = Map.put(rail_tracks(socket), id, tracks)
      {:noreply, apply_rail(socket, {socket.assigns.all_projects, tracks})}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:tracks, id}, {:ok, {:error, _reason}}, socket),
    do: {:noreply, track_load_failed(socket, id)}

  # The rail is what `handle_params/3` decides from, and a rail that arrived
  # on its own has no patch coming to decide again. So the two decisions a
  # patch would make are made here: a project that is open and no longer
  # listed is left, and a person whose last project just went is sent to the
  # walkthrough exactly as a mount would send them.
  def handle_async(:reload, {:ok, rail}, socket) do
    previous_project = socket.assigns.project
    socket = apply_rail(socket, rail)

    cond do
      previous_project &&
          not Enum.any?(socket.assigns.projects, &(&1.id == previous_project.id)) ->
        {:noreply, push_patch(socket, to: "/")}

      to = wrong_page(socket) ->
        {:noreply, push_navigate(socket, to: to)}

      params = socket.assigns.pending_url ->
        {:noreply, socket |> assign(pending_url: nil) |> open_url(params)}

      true ->
        {:noreply, socket}
    end
  end

  # Retry the initial read once after a short backoff. The retry remains a
  # LiveView async task so termination and session guards still own it.
  def handle_async(
        :reload,
        {:exit, _reason},
        %{assigns: %{rail_loaded: false, rail_retried: false}} = socket
      ) do
    {:noreply,
     socket
     |> assign(rail_retried: true)
     |> reload_async(fresh: true, backoff_ms: 100)}
  end

  # Exhausted initial reads need a visible way forward. Later failures retain
  # the loaded rail; the normal refresh path is still available.
  def handle_async(:reload, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, rail_error: !socket.assigns.rail_loaded)}

  def handle_async({:tracks, id}, {:exit, _reason}, socket),
    do: {:noreply, track_load_failed(socket, id)}

  def handle_async(name, {:exit, reason}, socket) when name in [:refs, :repos] do
    flag = if name == :refs, do: :refs_loading, else: :repos_loading
    {:noreply, socket |> assign(flag, false) |> exit(reason)}
  end

  def handle_async(_name, {:exit, reason}, socket),
    do: {:noreply, socket |> assign(busy: false) |> exit(reason)}

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
  # which used to ask Fountain live even on an ordinary page load. Now only
  # the changed project's turn read bypasses the memo. Somebody
  # with five projects therefore paid five or more round trips, in this
  # process, with the page unable to render or answer a click for the whole
  # of them, every time any agent anywhere started or finished a turn.
  #
  # A read mark is the third thing handled narrowly: it names the reader and
  # the track, and that is the whole of what it can change, so the rail
  # clears one dot from the event itself. See `:read` below.
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
  def handle_info({:track_host, pid}, socket),
    do:
      {:noreply,
       socket |> assign(track_host: pid) |> select_notice_thread(socket.assigns.track_id)}

  # A draft tab became a thread. The page already shows it; the URL names it
  # too, so a reload or a copied link lands on the thread rather than the
  # track's first one.
  def handle_info({:thread_started, track_id, thread_id}, socket) do
    if track_id == socket.assigns.track_id and socket.assigns.project,
      do:
        {:noreply,
         push_patch(socket,
           to: "/p/#{socket.assigns.project.id}/t/#{track_id}?thread=#{thread_id}"
         )},
      else: {:noreply, socket}
  end

  # The people dialog did the removal. Either way the rail is now wrong --
  # a project you just left goes, and a project you took somebody off has a
  # different set of tracks under it -- so it is re-read and the dialog
  # closes behind it.
  def handle_info({:person_removed, :project, _login}, socket),
    do: {:noreply, socket |> reload_async() |> push_patch(to: "/")}

  # A `live_component` cannot put a flash in the page's own socket, and the
  # nested track page has no toasts of its own, so both send the sentence
  # here; see `RavixWeb.Live.Result.flash/3`. The clear is that function's
  # timer for a notice, coming due.
  def handle_info({:flash, kind, message}, socket),
    do: {:noreply, flash(socket, kind, message)}

  def handle_info({:clear_flash, kind, message}, socket),
    do: {:noreply, clear_notice(socket, kind, message)}

  # The settings dialog saved a project's settings, which may have renamed
  # it. The rail on the left is showing the old name until it is re-read.
  def handle_info(:project_settings_saved, socket), do: {:noreply, reload_async(socket)}

  # The agent panel's clock; see `RavixWeb.Live.AgentPanel`.
  def handle_info({:agent_panel, id, tick}, %{assigns: %{dialog: :new_track}} = socket) do
    if ThreadConnect.active?(
         socket.assigns.current_user,
         track_project_id(socket),
         socket.assigns.thread_connect,
         id
       ),
       do: send_update(RavixWeb.Live.AgentPanel, id: id, tick: tick)

    {:noreply, socket}
  end

  def handle_info({:agent_panel, id, tick}, socket) do
    if (id == "agent-panel" and socket.assigns.dialog == :account) or
         (socket.assigns.dialog == :new_project and NewProject.active_panel?(socket, id)),
       do: send_update(RavixWeb.Live.AgentPanel, id: id, tick: tick)

    if (socket.assigns.dialog == :settings and socket.assigns.project) &&
         socket.assigns.project.role == :owner do
      send_update(RavixWeb.Live.SettingsDialog,
        id: "settings-dialog-panel",
        agent_tick: {id, tick}
      )
    end

    {:noreply, socket}
  end

  # The account dialog connected or replaced what pays for this person's
  # agent. The person on the page is now out of date, and the dialog has
  # already said what replacing it means for open tracks.
  # A creator-billed track's payer reconnecting their own agent: the account
  # dialog is always the signed-in person's own.
  def handle_info({:reconnect_own_agent, runtime}, socket) do
    agent = Map.get(%{"claude" => :claude, "claude-code" => :claude, "codex" => :codex}, runtime)
    {:noreply, assign(socket, dialog: :account, reconnect_agent: agent)}
  end

  def handle_info({:reconnect_agent, id}, socket) do
    case Access.project_of(socket.assigns.current_user, id) do
      {:ok, project} ->
        agent =
          Map.get(
            %{"claude" => :claude, "claude-code" => :claude, "codex" => :codex},
            project.runtime
          )

        {:noreply, assign(socket, dialog: :account, reconnect_agent: agent)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(
        {:agent_connected, %Accounts.User{} = user, agent},
        %{assigns: %{dialog: :new_track}} = socket
      ) do
    connection = socket.assigns.thread_connect

    socket =
      if connection &&
           user.id == socket.assigns.current_user.id && to_string(agent) == connection.runtime &&
           ThreadConnect.active?(
             user,
             track_project_id(socket),
             connection,
             connection.id
           ) do
        id = track_project_id(socket)

        params =
          socket.assigns.track_form.params
          |> Map.put("runtime", connection.runtime)
          |> Map.delete("model")

        socket
        |> assign(
          current_user: user,
          thread_connect: nil,
          track_form: Form.new(:new_track, params)
        )
        |> traced_async({:track_options, id}, fn -> Tracks.open_options(user, id) end)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:agent_connected, %Accounts.User{} = user, agent}, socket) do
    socket =
      if socket.assigns.dialog == :new_project,
        do: NewProject.connected(socket, user, agent),
        else: socket

    if socket.assigns.track_host, do: send(socket.assigns.track_host, :refresh_agent_health)
    socket = update(socket, :health_refresh, &(&1 + 1))

    if (socket.assigns.dialog == :settings and socket.assigns.project) &&
         socket.assigns.project.role == :owner do
      send_update(RavixWeb.Live.SettingsDialog,
        id: "settings-dialog-panel",
        connected_agent: agent
      )
    end

    default =
      if socket.assigns.current_user.agent != user.agent,
        do: " New projects default to #{agent_name(user)}.",
        else: ""

    name = RavixWeb.AgentName.label(Atom.to_string(agent))

    {:noreply,
     socket |> assign(current_user: user) |> flash(:info, "#{name} is connected." <> default)}
  end

  def handle_info({:agent_default_changed, %Accounts.User{} = user}, socket),
    do:
      {:noreply,
       socket
       |> assign(current_user: user)
       |> flash(:info, "New projects default to #{agent_name(user)}.")}

  def handle_info({:agent_disconnected, %Accounts.User{} = user, agent}, socket) do
    if socket.assigns.track_host, do: send(socket.assigns.track_host, :refresh_agent_health)
    socket = update(socket, :health_refresh, &(&1 + 1))

    {:noreply,
     socket
     |> assign(current_user: user)
     |> traced_async(:agent_disconnect_notice, fn ->
       case Accounts.Inference.usable?(user, agent, fresh: true) do
         {:ok, false} ->
           names =
             Projects.list(user, include_machine: false)
             |> Enum.filter(&(&1.role == :owner and &1.runtime == Atom.to_string(agent)))
             |> Enum.map_join(", ", & &1.name)

           if names == "",
             do: "Removed.",
             else:
               "Removed. Connect #{RavixWeb.AgentName.label(Atom.to_string(agent))} again to run: #{names}."

         _ ->
           "Removed."
       end
     end)}
  end

  # A rebuild closed every track on the project and a delete removed it
  # outright. Either way this is no longer somewhere to be, and a component
  # cannot patch the URL.
  def handle_info({:plan_saved, project_id, plan_id}, socket) do
    case Ravix.Plans.access(socket.assigns.current_user, plan_id) do
      {:ok, %{project_id: ^project_id}, _} ->
        {:noreply, push_patch(socket, to: "/p/#{project_id}/plans?plan=#{plan_id}")}

      _ ->
        {:noreply, reload_async(socket)}
    end
  end

  def handle_info(:project_left_behind, socket),
    do: {:noreply, socket |> reload_async() |> push_patch(to: "/")}

  def handle_info({:hub, %Event{name: name}}, socket) when name in [:here, :queue],
    do: {:noreply, socket}

  def handle_info({:hub, %Event{name: :turn, project_id: id}}, socket),
    do: {:noreply, refresh_tracks(socket, id)}

  # A comment moves unread marks and mentions, which are this database's, not
  # Fountain's; so the project's tracks are re-read from the memo.
  def handle_info({:hub, %Event{name: :comment, project_id: id}}, socket),
    do: {:noreply, refresh_tracks(socket, id, fresh: false)}

  # A machine went to sleep or woke: the row says so, and the memo serves
  # everything else, so nothing is asked of Fountain.
  def handle_info({:hub, %Event{name: :machine, project_id: id}}, socket),
    do: {:noreply, refresh_tracks(socket, id, fresh: false)}

  # A read mark is one person's own, and the only thing on this page it can
  # move is that person's unread dot on the track it names. So it is applied
  # to the rail in hand and reads nothing: not Fountain, not the database.
  # Every tab this person has open hears it, which is why it comes over the
  # hub rather than from the nested track page directly; everybody else's
  # rail hears it and has nothing to do. It used to arrive as `:tracks` and
  # re-read the whole rail, live, in every rail on the project, whenever
  # anybody opened a track.
  def handle_info({:hub, %Event{name: :read} = event}, socket),
    do: {:noreply, clear_unread(socket, event)}

  def handle_info({:hub, %Event{name: name}}, socket) when name in [:people, :tracks] do
    # An open project people dialog re-reads who is in it and whether the
    # viewer may still manage them (ADR 0010).
    if name == :people and socket.assigns[:dialog] == :people,
      do: send_update(RavixWeb.Live.PeopleDialog, id: "people", reload: true)

    {:noreply, socket |> recheck_or_leave() |> reload_async()}
  end

  def handle_info({:hub, %Event{}}, socket), do: {:noreply, reload_async(socket)}

  # The current workspace's members changed, perhaps to leave this viewer
  # out: scope again, falling back to the default if so. A project that goes
  # with it is left here, since this notice can beat the project's own
  # `:people` event, which would then find nothing open to leave.
  def handle_info({:workspace_hub, _id, :members}, socket),
    do: {:noreply, recheck_or_leave(socket)}

  defp clear_unread(
         %{assigns: %{current_user: %Accounts.User{id: user_id}, all_tracks: tracks}} = socket,
         %Event{
           user_id: user_id,
           project_id: project_id,
           track_id: track_id,
           thread_id: thread_id
         }
       )
       when is_binary(track_id) do
    case Map.fetch(tracks, project_id) do
      {:ok, rows} ->
        rows = Enum.map(rows, &clear_thread_unread(&1, track_id, thread_id || track_id))

        tracks = Map.put(tracks, project_id, rows)

        socket
        |> assign(all_tracks: tracks)
        |> derive_scope()
        |> announce(tracks)

      :error ->
        socket
    end
  end

  defp clear_unread(socket, _somebody_elses), do: socket

  defp clear_thread_unread(%{id: id} = row, id, thread_id) do
    threads =
      Enum.map(
        row.threads,
        &if(&1.id == thread_id,
          do: Map.merge(&1, %{unread: false, reply_unread: false, mention: nil}),
          else: &1
        )
      )

    %{
      row
      | threads: threads,
        unread: Enum.any?(threads, & &1.unread),
        reply_unread: Enum.any?(threads, &reply_unread?/1),
        mention: Enum.find_value(threads, &Map.get(&1, :mention))
    }
  end

  defp clear_thread_unread(row, _track_id, _thread_id), do: row

  defp section_result(socket, {:ok, _}) do
    {sections, placements} = Sections.list(socket.assigns.current_user)
    {:noreply, assign(socket, sections: sections, section_placements: placements)}
  end

  defp section_result(socket, {:error, reason}) do
    {:noreply, put_flash(socket, :error, RavixWeb.Error.from(reason).message)}
  end

  # The named sections first, then whatever is in none of them. Last, so the
  # Projects heading is never followed straight away by a second heading
  # saying "Other projects"; with no named sections at all the group has no
  # heading and its projects sit directly under Projects.
  # With `scratch_group` (RAVIX_WORKSPACE_ACCESS on), scratch projects leave
  # the sections for a group of their own after them (ADR 0009 phase 4c),
  # outside repository deduplication and the New track repository list.
  #
  # Legacy projects somebody shared with this person sit last, in "Shared
  # with you", while their personal workspace is current (`scope_rail/2`).
  defp section_groups(projects, sections, placements, scratch_group, shared_ids) do
    {shared, projects} = Enum.split_with(projects, &MapSet.member?(shared_ids, &1.id))

    groups = own_groups(projects, sections, placements, scratch_group)

    if shared == [],
      do: groups,
      else:
        groups ++ [{%{id: nil, name: "Shared with you", collapsed: false, shared: true}, shared}]
  end

  defp own_groups(projects, sections, placements, scratch_group) do
    {scratch, repos} =
      if scratch_group, do: Enum.split_with(projects, &is_nil(&1.repo)), else: {[], projects}

    grouped = Enum.group_by(repos, &Map.get(placements, &1.id))
    unsectioned = %{id: nil, name: "Other projects", collapsed: false}
    groups = Enum.map(sections ++ [unsectioned], &{&1, Map.get(grouped, &1.id, [])})

    if scratch == [],
      do: groups,
      else: groups ++ [{%{id: nil, name: "Scratch", collapsed: false, scratch: true}, scratch}]
  end

  # The scratch and shared groups are maps standing in for a section; real
  # sections are `Ravix.Projects.Section` structs, which do not answer
  # `section[:key]`. Neither takes a dragged project.
  defp scratch_section?(section),
    do: Map.get(section, :scratch) == true or Map.get(section, :shared) == true

  # A group has a header, and its projects sit a step in under it, once the
  # person has sections of their own or the group is scratch or shared.
  # Unsectioned projects with nothing else beside them need no label.
  defp section_labelled?(section, sections),
    do: not is_nil(section.id) or sections != [] or scratch_section?(section)

  defp section_key(%{scratch: true}), do: "scratch"
  defp section_key(%{shared: true}), do: "shared"
  defp section_key(%{id: nil}), do: "other"
  defp section_key(%{id: id}), do: id

  # Scope again from the database, and leave the open project if that took
  # it away.
  defp recheck_or_leave(socket) do
    previous_project = socket.assigns.project
    socket = recheck_rail(socket)

    if previous_project && is_nil(socket.assigns.project),
      do: push_patch(socket, to: "/"),
      else: socket
  end

  # Only the connected, already-loaded rail is revalidated here. Initial
  # discovery remains in start_async; this reads membership, never providers.
  defp recheck_rail(%{assigns: %{rail_loaded: true, current_user: %Accounts.User{}}} = socket),
    do: apply_rail(socket, {socket.assigns.all_projects, rail_tracks(socket)})

  defp recheck_rail(socket), do: socket

  defp project_matches?(project, query),
    do:
      String.contains?(String.downcase(project.display_name), String.downcase(String.trim(query)))

  defp project_attention(tracks, id), do: Enum.count(Map.get(tracks, id, []), &attention?/1)

  # start_async does not run on the disconnected render. The connected mount
  # starts the same traced read as subsequent refreshes, leaving the shell free
  # to render and the selected track free to mount independently.
  defp reload_async(socket, opts \\ [])
  defp reload_async(%{assigns: %{current_user: nil}} = socket, _opts), do: socket

  defp reload_async(socket, opts) do
    user = socket.assigns.current_user
    {backoff, opts} = Keyword.pop(opts, :backoff_ms, 0)
    opts = Keyword.put(opts, :closed_pages, socket.assigns.closed_pages)

    traced_async(assign(socket, rail_error: false), :reload, fn ->
      if backoff > 0, do: Process.sleep(backoff)
      read_rail(user, opts)
    end)
  end

  # The two creates, once they have something to show. The page patches to
  # what was created, and `handle_params/3` will only open a project that is
  # in the rail, so the rail is read here, in the task that did the creating,
  # and arrives in the same answer. Off this process, as every rail read
  # is, and in hand before the patch, which a `reload_async/1` could
  # not promise.
  # A prompt typed into the create dialog is the track's first message: it
  # goes through the same queue as one sent from the composer, on the
  # default thread, and waits there until setup is ready. The track is
  # already open by then, so a refused prompt does not undo it; the page
  # opens the track and says the prompt was not queued.
  defp open_track(user, project_id, attrs, prompt) do
    with {:ok, track} <- Tracks.open(user, project_id, attrs) do
      if String.trim(prompt) == "",
        do: {:ok, {track, :none}},
        else:
          {:ok,
           {track,
            Tracks.prompt(user, track.id, %{prompt: prompt, request_id: Ecto.UUID.generate()})}}
    end
  end

  defp first_prompt_refused(socket, {:error, reason}),
    do:
      put_flash(
        socket,
        :error,
        "The track opened, but its first prompt was not queued. #{RavixWeb.Error.from(reason).message}"
      )

  defp first_prompt_refused(socket, _queued), do: socket

  defp created({:ok, value}, user), do: {:ok, {value, read_rail(user)}}
  defp created(response, _user), do: response

  defp rail_tracks(socket) do
    all =
      Map.merge(socket.assigns.all_tracks, socket.assigns.closed_tracks, fn _, a, b -> a ++ b end)

    Enum.reduce(socket.assigns.track_errors, all, fn id, tracks ->
      Map.put(tracks, id, {:error, :unavailable})
    end)
  end

  defp finish_track_load(socket, id),
    do: assign(socket, :track_loading, MapSet.delete(socket.assigns.track_loading, id))

  defp track_load_failed(socket, id) do
    socket = finish_track_load(socket, id)
    tracks = Map.put(rail_tracks(socket), id, {:error, :unavailable})
    apply_rail(socket, {socket.assigns.all_projects, tracks})
  end

  defp refresh_tracks(socket, project_id, opts \\ [fresh: true])

  defp refresh_tracks(%{assigns: %{current_user: nil}} = socket, _id, _opts), do: socket

  defp refresh_tracks(socket, project_id, opts) do
    if Enum.any?(socket.assigns.all_projects, &(&1.id == project_id)) do
      user = socket.assigns.current_user

      socket =
        assign(socket, :track_loading, MapSet.put(socket.assigns.track_loading, project_id))

      fresh = Keyword.get(opts, :fresh, true)

      opts =
        if MapSet.member?(socket.assigns.closed_projects, project_id),
          do: [fresh: fresh, closed: closed_fetch(socket.assigns.closed_pages, project_id)],
          else: [fresh: fresh]

      traced_async(socket, {:tracks, project_id}, fn -> Tracks.list(user, project_id, opts) end)
    else
      socket
    end
  end

  # Discover projects and tracks off the LiveView process. Tracks batches the
  # scoped database read and bounds provider presentation independently per
  # project. The rail does not display machine state; reading it again here
  # would repeat timed-out requests or expire a fast project's memo while
  # another project is still answering.
  defp read_rail(user, opts \\ []) do
    projects = Projects.list(user, include_machine: false)
    {pages, opts} = Keyword.pop(opts, :closed_pages, %{})
    closed = closed_limits(user, projects, pages)
    tracks = Tracks.list_many(user, Enum.map(projects, & &1.id), [closed: closed] ++ opts)
    {projects, tracks}
  end

  # Subscribing is this process's to do --- `Phoenix.PubSub` registers the
  # caller --- so it happens here rather than beside the reads above.
  defp apply_rail(socket, {_loaded_projects, tracks}) do
    # The session hook runs before handle_async. Membership may also have
    # changed while Fountain was answering, before this page subscribed.
    # This authorization recheck must not restart timed-out provider reads.
    projects =
      socket.assigns.current_user
      |> Projects.list(include_machine: false)

    closed = closed_limits(socket.assigns.current_user, projects, socket.assigns.closed_pages)
    closed_projects = MapSet.new(Map.keys(closed))

    visible =
      socket.assigns.current_user
      |> Access.open_tracks(Enum.map(projects, & &1.id), closed: closed)
      |> MapSet.new(fn {row, _project} -> row.id end)

    track_errors =
      projects
      |> Enum.filter(&(Map.get(tracks, &1.id) == {:error, :unavailable}))
      |> MapSet.new(& &1.id)

    tracks =
      Map.new(projects, fn project ->
        rows =
          if MapSet.member?(track_errors, project.id),
            do: [],
            else: Map.get(tracks, project.id, [])

        rows = Enum.filter(rows, &MapSet.member?(visible, &1.id))
        {project.id, rows}
      end)

    {closed_tracks, tracks} =
      Enum.reduce(tracks, {%{}, %{}}, fn {id, rows}, {closed, open} ->
        {shut, live} = Enum.split_with(rows, &(&1.status == :closed))

        closed =
          if MapSet.member?(closed_projects, id),
            do: Map.put(closed, id, Enum.sort_by(shut, & &1.closed_at, {:desc, DateTime})),
            else: closed

        {closed, Map.put(open, id, live)}
      end)

    {sections, placements} = Sections.list(socket.assigns.current_user)

    if connected?(socket) do
      old = MapSet.new(socket.assigns.all_projects, & &1.id)
      new = MapSet.new(projects, & &1.id)
      Enum.each(MapSet.difference(old, new), &Hub.unsubscribe/1)
      Enum.each(MapSet.difference(new, old), &Hub.subscribe/1)
    end

    socket
    |> assign(
      rail_loaded: true,
      rail_error: false,
      sections: sections,
      section_placements: placements,
      all_projects: projects,
      all_tracks: tracks,
      all_notices: People.notices(socket.assigns.current_user),
      closed_tracks: closed_tracks,
      closed_projects: closed_projects,
      track_errors: track_errors
    )
    |> scope_rail(socket.assigns.url_project)
    |> assign(url_project: nil)
    |> refresh_picker()
    |> assign_page_title()
    |> announce(tracks)
  end

  # Cut the page's scope from everything the viewer reaches (ADR 0009): the
  # current workspace's projects, and in the personal workspace the legacy
  # projects somebody shared, as "Shared with you". The current workspace is
  # read again here, through `Access.workspace_access/2`, on every rail read,
  # so a membership revoked since the choice was made falls back to the
  # default. Nothing is read from a provider and nothing is granted: the
  # projects are `Projects.list/2`'s, already admitted one by one.
  #
  # `follow` is a project a URL just named, on mount or a patch. When it is
  # one the viewer reaches but sits in another of their workspaces, that
  # workspace becomes current, so a `/p/:id` link from somewhere else opens
  # where it lives rather than as "not found". A background read follows
  # only the project whose settings this page has open: a project is moved
  # there, by its owner, so that is this page's own move ("Move to
  # workspace…"). Anything else moved elsewhere while open -- anybody's,
  # or the owner's own from another tab -- leaves the page, and the choice
  # of workspace stays as it was.
  defp scope_rail(socket, follow) do
    user = socket.assigns.current_user
    listed = WorkspaceSwitcher.list(user)
    all = socket.assigns.all_projects
    follow = follow || moving_here(socket)
    current = current_workspace(user, listed)

    parts = Workspaces.partition(user, current && current.workspace, listed, all)

    {user, current, parts} =
      with id when is_binary(id) <- follow,
           %{} = view <- Enum.find(parts.other, &(&1.id == id)),
           home when is_binary(home) <- Workspaces.home(user, listed, view),
           {:ok, user} <- Accounts.put_current_workspace(user, home),
           {:ok, current} <- Workspaces.current(user, listed) do
        {user, current, Workspaces.partition(user, current.workspace, listed, all)}
      else
        _ -> {user, current, parts}
      end

    shown = MapSet.new(parts.current ++ parts.shared, & &1.id)
    projects = Enum.filter(all, &MapSet.member?(shown, &1.id))
    project = socket.assigns.project && Enum.find(projects, &(&1.id == socket.assigns.project.id))

    socket
    |> watch_workspace(current)
    |> assign(
      current_user: user,
      workspaces: listed,
      current_workspace: current,
      projects: projects,
      shared_ids: MapSet.new(parts.shared, & &1.id),
      project: project,
      track_project:
        socket.assigns.track_project &&
          Enum.find(projects, &(&1.id == track_project_id(socket) && &1.access != :tracks))
    )
    |> derive_scope()
  end

  # The one resolution of the current workspace, for the mount and for every
  # rail read: the session's own user, through `Access.workspace_access/2`.
  defp current_workspace(nil, _listed), do: nil

  defp current_workspace(user, listed) do
    case Workspaces.current(user, listed) do
      {:ok, current} -> current
      {:error, :not_found} -> nil
    end
  end

  defp moving_here(%{assigns: %{dialog: :settings, project: %{id: id}, all_projects: all}}) do
    if Enum.any?(all, &(&1.id == id and &1.access == :owner)), do: id
  end

  defp moving_here(_socket), do: nil

  # A `/p/:id` link to a project the viewer reaches in another of their
  # workspaces switches to it; anything else is left to `open_url/2`.
  defp follow(socket, id) when is_binary(id) do
    in_scope? = Enum.any?(socket.assigns.projects, &(&1.id == id))
    reachable? = Enum.any?(socket.assigns.all_projects, &(&1.id == id))
    if reachable? and not in_scope?, do: scope_rail(socket, id), else: socket
  end

  defp follow(socket, _id), do: socket

  # The current workspace's own membership notices, so a page whose viewer
  # is removed from it re-scopes at once, even with no project there to
  # carry the `:people` event.
  defp watch_workspace(socket, current) do
    id = current && current.workspace.id
    was = socket.assigns[:watched_workspace]

    if connected?(socket) and id != was do
      if was, do: Hub.unsubscribe_workspace(was)
      if id, do: Hub.subscribe_workspace(id)
    end

    assign(socket, watched_workspace: id)
  end

  # The scoped tracks, badges and Inbox from what the rail holds: no reads.
  # Access notices name their track's workspace and are scoped with it; one
  # for a workspace the viewer is not in stays, never hidden.
  defp derive_scope(socket) do
    %{all_tracks: all, projects: projects, all_notices: notices} = socket.assigns
    ids = MapSet.new(projects, & &1.id)
    {here, elsewhere} = Enum.split_with(all, fn {id, _rows} -> MapSet.member?(ids, id) end)
    {shown, hidden} = Enum.split_with(notices, &notice_here?(&1, socket.assigns))
    tracks = Map.new(here)

    assign(socket,
      tracks: tracks,
      access_notices: shown,
      attention: attention_count(tracks) + length(shown),
      other_attention: attention_count(elsewhere) + length(hidden)
    )
  end

  defp notice_here?(_notice, %{current_workspace: nil}), do: true

  defp notice_here?(notice, %{current_workspace: %{workspace: current}, workspaces: listed}),
    do:
      notice.workspace_id == current.id or
        not Enum.any?(listed, &(&1.workspace.id == notice.workspace_id))

  # The repository list is the rail's, so it is read again with the rail: a
  # project gained, lost or renamed shows there too, and the query, the add
  # step and a pending add carry over.
  defp refresh_picker(
         %{
           assigns: %{picker: %Picker{} = picker, dialog: :new_track, track_project: %{} = anchor}
         } =
           socket
       ) do
    rebuilt =
      Picker.build(
        socket.assigns.current_user,
        socket.assigns.projects,
        anchor,
        socket.assigns.current_workspace
      )

    assign(socket,
      picker: %{
        rebuilt
        | query: picker.query,
          mode: picker.mode,
          addable: picker.addable,
          adding: picker.adding
      }
    )
  end

  defp refresh_picker(socket), do: socket

  # Use the scoped rail already held by the workspace, including after a
  # background reload or rename, so the browser tab follows the visible page.
  # `requested` is the track a deep link named, found through scoped access
  # before the rail has arrived; the rail's own row wins once it is here.
  defp assign_page_title(socket, requested \\ nil)

  defp assign_page_title(%{assigns: %{project: nil, live_action: action}} = socket, _requested) do
    title =
      case action do
        :projects -> "Home"
        :schedules -> "Schedules"
        :connections -> "Connected applications"
        :login -> "Sign in"
        _ -> "Inbox"
      end

    assign(socket, page_title: title <> " · Ravix")
  end

  defp assign_page_title(%{assigns: assigns} = socket, requested) do
    project = assigns.project

    title =
      case Enum.find(assigns.tracks[project.id] || [], &(&1.id == assigns.track_id)) ||
             (requested && requested.id == assigns.track_id && requested) do
        nil when assigns.live_action == :plans -> "Plans · " <> project.display_name
        nil -> project.display_name
        track -> track.title <> " · " <> project.display_name
      end

    assign(socket, page_title: title <> " · Ravix")
  end

  defp select_notice_thread(
         %{assigns: %{notice_thread: {track_id, thread_id}, track_host: pid}} = socket,
         track_id
       )
       when is_pid(pid) do
    send(pid, {:select_thread, track_id, thread_id})
    assign(socket, notice_thread: nil)
  end

  defp select_notice_thread(socket, _track_id), do: socket

  # Seed silently on mount; subsequent transitions belong to individual threads.
  defp announce(socket, tracks) do
    wanting =
      for {_id, rows} <- tracks,
          track <- rows,
          thread <- notice_threads(track),
          attention?(thread),
          into: %{},
          do: {thread.id, notice(track, thread, socket.assigns.all_projects)}

    ids = MapSet.new(Map.keys(wanting))

    case socket.assigns.noticed do
      nil ->
        assign(socket, noticed: ids)

      noticed ->
        fresh =
          ids |> MapSet.difference(noticed) |> Enum.map(&wanting[&1]) |> Enum.sort_by(& &1.title)

        socket = assign(socket, noticed: ids)
        if fresh == [], do: socket, else: push_event(socket, "notify", %{tracks: fresh})
    end
  end

  defp notice_threads(%{status: :setup_failed} = track),
    do: [%{id: track.id, title: track.title, status: :failed}]

  defp notice_threads(%{setup_state: state}) when state in ["pending", "running", "retry"],
    do: []

  defp notice_threads(track), do: track.threads

  defp notice(track, thread, projects) do
    project = Enum.find(projects, &(&1.id == track.project_id))

    %{
      id: track.id,
      thread_id: thread.id,
      title: if(thread.id == track.id, do: track.title, else: "#{track.title} · #{thread.title}"),
      project: project && project.display_name,
      status: thread.status,
      mention: Map.get(thread, :mention) && thread.mention.author_login
    }
  end

  defp agent_name(%Accounts.User{agent: :codex}), do: "Codex"
  defp agent_name(%Accounts.User{}), do: "Claude Code"

  defp open_dialog(socket, :new_project),
    do:
      socket
      |> assign(dialog: :new_project)
      |> NewProject.init()
      |> load_repos(nil)

  defp open_dialog(socket, :new_track), do: new_track_dialog(socket, socket.assigns.project)

  defp open_dialog(socket, :sections), do: assign(socket, dialog: :sections)

  defp open_dialog(socket, :search),
    do:
      socket
      |> recheck_rail()
      |> assign(
        dialog: :search,
        query: "",
        search_plans: Ravix.Plans.titles(socket.assigns.current_user)
      )

  # The settings dialog loads and holds its own four forms, so opening it is
  # only opening it.
  defp open_dialog(socket, :settings), do: assign(socket, dialog: :settings)

  # The people dialog loads its own list, so opening it is only opening it.
  defp open_dialog(socket, :people), do: assign(socket, dialog: :people)

  # The account dialog is the agent panel, which holds its own state too.
  defp open_dialog(socket, :account), do: assign(socket, dialog: :account, reconnect_agent: nil)
  defp open_dialog(socket, :help), do: assign(socket, dialog: :help)
  defp open_dialog(socket, :changes), do: assign(socket, dialog: :changes)

  defp unseen(socket) do
    changes = Accounts.unseen_changes(socket.assigns.current_user)
    assign(socket, changes: changes, changes_unseen: length(changes))
  end

  defp mark_changes(socket) do
    entries = socket.assigns.changes

    case Ravix.Changelog.newest(entries) do
      nil ->
        socket

      entry ->
        {:ok, user} =
          Accounts.mark_changes_seen(socket.assigns.current_user, Ravix.Changelog.at(entry))

        assign(socket, current_user: user, changes_unseen: 0)
    end
  end

  # The repositories this person's installations can see: a GitHub call, off
  # this process for the same reason as the refs above. What is on offer is
  # cleared first, because the previous answer belongs to whichever
  # installation was selected last and offering it under a new one would let
  # somebody create a project against a repository this account cannot see.
  defp load_repos(socket, id) do
    if Accounts.capabilities().github do
      user = socket.assigns.current_user

      socket
      |> assign(repos_loading: true, repos: [], installations: [], installation: nil)
      |> traced_async(:repos, fn -> Projects.repos(user, id) end)
    else
      socket
    end
  end

  defp track_suffix(nil), do: ""
  defp track_suffix(id), do: "/t/#{id}"

  # How a workspace dialog closes. With a project selected, closing also
  # drops the dialog's query (`?new=track`, `?settings=true`), and the client
  # patches the URL itself: `handle_params/3` clears the dialog. A patch pushed
  # by the server instead took the URL back from a link clicked while the
  # close was in flight, leaving that track on screen under the old address
  # (RAV-68).
  defp dismiss(nil, _track_id), do: "dismiss"
  defp dismiss(project, track_id), do: JS.patch("/p/#{project.id}" <> track_suffix(track_id))

  # Today's New track, while RAVIX_WORKSPACE_ACCESS is off.
  defp top_new_track(socket, project) do
    project =
      if project && project.access != :tracks,
        do: project,
        else: Enum.find(socket.assigns.projects, &(&1.access != :tracks))

    if project,
      do: new_track_dialog(socket, project),
      else: open_dialog(socket, :new_project)
  end

  defp update_picker_adding(%{assigns: %{picker: %Picker{} = picker}} = socket),
    do: assign(socket, picker: %{picker | adding: nil})

  defp update_picker_adding(socket), do: socket

  defp new_track_dialog(socket, project) when is_nil(project) or project.access == :tracks,
    do: flash(socket, :error, "Project not available.")

  defp new_track_dialog(socket, project) do
    if Workspaces.enabled?(),
      do: picker_dialog(socket, project),
      else: legacy_new_track_dialog(socket, project)
  end

  # RAV-10: the current workspace's repositories, the anchor (or the most
  # recently used) preselected. Nothing to preselect at all is today's
  # answer to a person with no project: the New project dialog.
  defp picker_dialog(socket, anchor) do
    # A deep link (`?new=track`) can open this before the rail has arrived;
    # the project it names is listed meanwhile, and `refresh_picker/1` fills
    # in the rest when the rail lands.
    views =
      if anchor,
        do: [anchor | Enum.reject(socket.assigns.projects, &(&1.id == anchor.id))],
        else: socket.assigns.projects

    picker =
      Picker.build(socket.assigns.current_user, views, anchor, socket.assigns.current_workspace)

    case Picker.preselect(picker, anchor) do
      nil ->
        socket |> assign(picker: nil) |> open_dialog(:new_project)

      project ->
        socket
        |> assign(
          dialog: :new_track,
          track_form: Form.new(:new_track),
          advanced_track: false,
          picker: picker
        )
        |> choose_track_project(project)
    end
  end

  defp legacy_new_track_dialog(socket, project) do
    socket
    |> assign(
      dialog: :new_track,
      track_form: Form.new(:new_track),
      advanced_track: false,
      picker: nil
    )
    |> choose_track_project(project)
  end

  # The dialog owns its destination. Changing it must not navigate the page or
  # discard the branch/sharing draft; only project-dependent choices expire.
  defp choose_track_project(socket, project) do
    user = socket.assigns.current_user
    id = project.id
    params = Map.drop(socket.assigns.track_form.params, ["runtime", "model", "ref"])

    socket
    |> cancel_async(:refs)
    |> assign(
      track_project: project,
      track_form: Form.new(:new_track, params),
      track_options: nil,
      thread_connect: nil,
      origin_kind: :blank,
      refs: [],
      refs_loading: false,
      reopen: nil
    )
    |> traced_async({:track_options, id}, fn -> Tracks.open_options(user, id) end)
  end

  defp choose_origin(socket, kind) do
    socket =
      assign(socket, origin_kind: kind, refs: [], refs_loading: false, advanced_track: true)

    case @origin_refs[kind] do
      nil ->
        socket

      refs_kind ->
        # A GitHub call, and it used to be one this process waited out: the
        # rail stopped drawing and the dialog stopped answering for as long
        # as the repository took to list its branches. The form's own
        # "Create track" stays disabled until the refs land, which is what
        # already said "not yet" while this was synchronous too.
        user = socket.assigns.current_user
        id = track_project_id(socket)

        traced_async(assign(socket, refs_loading: true), :refs, fn ->
          Projects.refs(user, id, refs_kind)
        end)
    end
  end

  # Show closed belongs to the project row menu, which somebody invited only
  # to tracks does not have; a choice made before losing project access lapses.
  #
  # Each shown project lists a page of its most recently closed tracks at a
  # time, fetching one more than it shows so the page knows there are older.
  defp closed_limits(user, projects, pages) do
    ids = for p <- projects, p.access != :tracks, into: MapSet.new(), do: p.id

    for id <- Sections.closed_shown(user),
        MapSet.member?(ids, id),
        into: %{},
        do: {id, closed_fetch(pages, id)}
  end

  @closed_page 20
  defp closed_shown_count(pages, id), do: Map.get(pages, id, 1) * @closed_page
  defp closed_fetch(pages, id), do: closed_shown_count(pages, id) + 1

  defp toggle(set, id, true), do: MapSet.put(set, id)
  defp toggle(set, id, false), do: MapSet.delete(set, id)

  defp reopenable?(project), do: not is_nil(project.repo)

  defp track_project_id(socket),
    do: socket.assigns.track_project && socket.assigns.track_project.id

  defp project_id(socket), do: socket.assigns.project && socket.assigns.project.id
  defp ref_id(%{number: number}), do: to_string(number)
  defp ref_id(%{name: name}), do: name
  defp ref_label(%{number: number, title: title}), do: "##{number} #{title}"
  defp ref_label(%{name: name}), do: name

  # The New track chips (RAV-60): where the track opens, and who sees it.
  defp track_destination(%{repo: repo}) when is_binary(repo), do: repo
  defp track_destination(project), do: "Scratch · #{project.display_name}"

  defp private_tracks?(user), do: Ravix.Config.dedicated_opens_enabled?(user)

  defp sharing_choices,
    do: [
      {"project", "Everyone", "Everyone in this project"},
      {"private", "Only me", "Only me and the people I invite"}
    ]

  defp sharing_label("private"), do: "Only me"
  defp sharing_label(_visibility), do: "Everyone"

  defp attention_count(tracks),
    do:
      Enum.reduce(tracks, 0, fn {_id, rows}, count -> count + Enum.count(rows, &attention?/1) end)

  # A mention is dated by the comment; everything else by the agent.
  defp inbox_time(%{status: status, mention: %{at: at}})
       when status not in [:failed, :setup_failed],
       do: at

  defp inbox_time(track), do: track.last_active_at

  # What the Inbox lists: a failure, a reply nobody has read, a comment
  # naming this person, or a creator-billed track of theirs paused on their
  # credential. A comment that names nobody moves only the dot.
  defp attention?(track),
    do:
      billing_attention?(track) or track.status in [:failed, :setup_failed] or
        (track.status == :ready and reply_unread?(track)) or
        Map.get(track, :mention) != nil

  # While creator billing is on, whoever opens a track pays for it, so New
  # track waits for them to connect a harness of their own; the server
  # refuses the same open for web and MCP alike (`Tracks.open/4`).
  defp creator_blocked?(%{billing: :creator, runtimes: runtimes}),
    do: not Enum.any?(runtimes, &(&1.connected and &1.enabled))

  defp creator_blocked?(_options), do: false

  # A creator-billed track paused on its creator's credential is the
  # creator's to reconnect, so it is in their Inbox and nobody else's.
  defp billing_attention?(track),
    do: Map.get(track, :payer?) == true and Map.get(track, :billing_pause) != nil

  defp reply_unread?(track) do
    case Map.get(track, :reply_unread) do
      nil -> track.unread
      value -> value
    end
  end

  # A tab's dot, from what the rail already read: nothing new is asked of
  # Fountain to draw it. `MachineState` is the one place the state is decided,
  # so the dot, the header chip and the dock say the same word.
  defp tab_machine(track), do: MachineState.of(track)

  # An unread row says whether a reply or only a comment is waiting.
  defp tab_status(track) do
    case MachineState.marker(tab_machine(track), track.unread) do
      :unread -> if(reply_unread?(track), do: :unread, else: :commented)
      marker -> marker
    end
  end

  defp tab_status_label(:unread), do: "Unread reply"
  defp tab_status_label(:commented), do: "New comment"
  defp tab_status_label(state), do: MachineState.label(state)

  # The dot's tooltip: the state, and what it means when there is more to say.
  defp tab_status_title(track) do
    machine = tab_machine(track)

    case tab_status(track) do
      marker when marker in [:unread, :commented] ->
        "#{tab_status_label(marker)} · #{MachineState.label(machine.state)}"

      state when is_nil(machine.detail) ->
        tab_status_label(state)

      state ->
        "#{tab_status_label(state)}: #{machine.detail}"
    end
  end

  defp tab_label(%{title: title}) do
    namespace = Ids.branch_namespace()
    if title != namespace, do: String.replace_prefix(title, namespace, ""), else: title
  end

  # The link's accessible name: what the tab draws, less the abbreviation.
  defp tab_name(track) do
    [
      track.title,
      "created by @#{track.created_by_login}",
      track.origin.kind == :plan && "from a project plan",
      MachineState.label(tab_machine(track).state),
      (marker = tab_status(track)) in [:unread, :commented] && tab_status_label(marker)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  # The sidebar's Mine filter. The selected track stays, so choosing Mine
  # never takes away the page somebody is looking at.
  defp rail_rows(rows, %Accounts.User{rail_scope: :mine} = user, selected),
    do: Enum.filter(rows, &(&1.id == selected or Access.created_by?(user, &1)))

  defp rail_rows(rows, _user, _selected), do: rows

  # Quick-jump searches everything unless the query says `mine:`.
  defp jump_query(query) do
    words = String.split(query)
    {"mine:" in words, words |> Enum.reject(&(&1 == "mine:")) |> Enum.join(" ")}
  end

  # A row's dot sits in a slot of its own width whether or not there is one,
  # so every row's avatar and title start at the same x.
  attr :track, :map, required: true

  defp status_slot(assigns) do
    assigns = assign(assigns, :status, tab_status(assigns.track))

    ~H"""
    <span class="track-status" aria-hidden={if is_nil(@status), do: "true"}>
      <.status_dot
        :if={@status}
        status={to_string(@status)}
        label={tab_status_label(@status)}
        title={tab_status_title(@track)}
      />
    </span>
    """
  end

  attr :track, :map, required: true

  defp creator(assigns) do
    ~H"""
    <span
      class="track-creator"
      role="img"
      aria-label={"Created by @#{@track.created_by_login}"}
      title={"Created by @#{@track.created_by_login}"}
    >
      <img :if={@track.creator_avatar_url} src={@track.creator_avatar_url} alt="" loading="lazy" />
      <span :if={!@track.creator_avatar_url} aria-hidden="true">{initials(@track.created_by_login)}</span>
    </span>
    """
  end

  # A row's last-activity age. The server writes it once, relative to the
  # render; the `RelativeTime` hook keeps it current and puts the time in the
  # viewer's own zone in the tooltip.
  attr :id, :string, required: true
  attr :at, DateTime, default: nil

  defp age(assigns) do
    ~H"""
    <time
      :if={@at}
      id={@id}
      class="track-age"
      phx-hook="RelativeTime"
      datetime={DateTime.to_iso8601(@at)}
      title={"Last active #{Calendar.strftime(@at, "%b %-d, %Y %H:%M UTC")}"}
    >{elem(ago(@at), 0)}</time>
    """
  end

  # The link's accessible name, with the age the hook keeps current in words.
  defp row_label(track, label) do
    case track.activity_at do
      nil -> label
      at -> "#{label}, active #{elem(ago(at), 1)}"
    end
  end

  @ages [
    {365 * 86_400, "y", "year"},
    {30 * 86_400, "mo", "month"},
    {86_400, "d", "day"},
    {3_600, "h", "hour"},
    {60, "m", "minute"}
  ]

  # `{short, words}`, as assets/js/hooks/relative_time.js's `age` answers it.
  defp ago(at, now \\ DateTime.utc_now()) do
    seconds = max(DateTime.diff(now, at), 0)

    case Enum.find(@ages, fn {size, _, _} -> seconds >= size end) do
      nil ->
        {"now", "just now"}

      {size, short, word} ->
        n = div(seconds, size)
        {"#{n}#{short}", "#{n} #{word}#{if n == 1, do: "", else: "s"} ago"}
    end
  end

  defp initials(login) do
    case String.split(login || "", ~r/[-_.]+/, trim: true) do
      [first, second | _] -> String.first(first) <> String.first(second)
      [only] -> String.slice(only, 0, 2)
      [] -> "?"
    end
    |> String.upcase()
  end

  defp jump_tracks(tracks, project, user, mine?, query),
    do:
      Enum.filter(
        tracks,
        &((!mine? or Access.created_by?(user, &1)) and matching?(&1, project, query))
      )

  # Only a project this person may enter whole has plans to offer, and
  # `mine:` is about the tracks this person created.
  defp jump_plans(_plans, %{access: :tracks}, _mine?, _query), do: []
  defp jump_plans(_plans, _project, true, _query), do: []

  defp jump_plans(plans, _project, false, query),
    do: Enum.filter(plans, &plan_matches?(&1, query))

  # Keep filtering inside a component so HEEx tracks its input assigns.
  defp track_search_results(assigns) do
    plans = Enum.group_by(assigns.plans, & &1.project_id)
    {mine?, query} = jump_query(assigns.query)

    results =
      for project <- assigns.projects,
          tracks =
            jump_tracks(assigns.tracks[project.id] || [], project, assigns.user, mine?, query),
          plans = jump_plans(plans[project.id] || [], project, mine?, query),
          tracks != [] || plans != [] || (!mine? and project_matches?(project, query)),
          do: {project, tracks, plans}

    assigns = assign(assigns, results: results, query: query)

    ~H"""
    <p :if={@results == []} role="status">No projects, tracks or plans match</p>
    <section
      :for={{project, tracks, plans} <- @results}
      id={"search-group-#{project.id}"}
      aria-labelledby={"search-project-#{project.id}"}
    >
      <h3 id={"search-project-#{project.id}"}>
        <.link
          :if={project_matches?(project, @query)}
          id={"search-project-link-#{project.id}"}
          patch={"/p/#{project.id}"}
          data-jump-result
        >
          {project.display_name}
          <span
            :if={project_attention(@tracks, project.id) > 0}
            class="badge"
            aria-label={"#{project_attention(@tracks, project.id)} unread"}
          >{project_attention(
            @tracks,
            project.id
          )}</span>
        </.link>
        <span :if={!project_matches?(project, @query)}>{project.display_name}</span>
      </h3>
      <.link
        :for={track <- tracks}
        id={"search-track-link-#{track.id}"}
        patch={"/p/#{project.id}/t/#{track.id}"}
        class="workspace-track"
        data-jump-result
      >
        {track.title}<span :if={track.visibility == :private}><.icon name="lock" /> Private</span>
        <span :if={attention?(track)} class="badge" aria-label="1 unread">1</span>
      </.link>
      <.link
        :for={plan <- plans}
        id={"search-plan-link-#{plan.id}"}
        patch={"/p/#{project.id}/plans?plan=#{plan.id}"}
        class="workspace-track"
        data-jump-result
      >
        <.icon name="document" size={13} /><span>Plan: {plan.title}</span><span
          :if={plan.archived}
          class="chip"
        >Archived</span>
      </.link>
    </section>
    """
  end

  defp plan_matches?(plan, query),
    do: String.contains?(String.downcase(plan.title), String.downcase(query))

  defp matching?(track, project, query),
    do:
      String.contains?(
        String.downcase("#{project.owner_login} #{project.name} #{track.title} #{track.branch}"),
        String.downcase(query)
      )
end
