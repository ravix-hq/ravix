defmodule RavixWeb.WorkspacePeopleLive do
  @moduledoc """
  One workspace's page: who is in it, who is invited, and the invite box
  (ADR 0009, phase 4a). Where the gear beside the switcher's current
  workspace goes.

  Behind `RAVIX_WORKSPACE_ACCESS`: with the switch off every workspace is
  not found here, as `Ravix.Workspaces.people/2` answers. The page holds its
  workspace through `RavixWeb.Live.WorkspaceGuard`, so a member removed
  while it is open is sent home on the next event, patch, async result or
  hub notice, and redraws the lists on the notice otherwise.

  Owners and admins invite by GitHub login, with suggestions from the
  people who have signed in here, withdraw waiting invitations and remove
  members; owners also change roles. Every one of those is decided again by
  the context; the page only hides the controls a role cannot use.

  Phase 4b adds the workspace's GitHub (`RavixWeb.Live.WorkspaceGitHub`):
  its connections, "Connect GitHub" for owners and admins, and the
  repository catalog, read from the cache and refreshed from GitHub in the
  background when stale or asked. Adding a repository opens its project,
  the existing one when the workspace already has it.
  """
  use RavixWeb, :live_view

  alias Ravix.{Accounts, People, Workspaces}
  alias Ravix.Workspaces.{Installation, Invite, Repositories}
  alias RavixWeb.Live.{WorkspaceGitHub, WorkspaceGuard, WorkspaceSwitcher}

  # How old the catalog may be before opening the page refreshes it.
  @stale_ms 10 * 60 * 1000

  @impl true
  def mount(%{"workspace" => id}, _session, socket) do
    user = socket.assigns[:current_user]

    with %Accounts.User{} <- user,
         {:ok, people} <- Workspaces.people(user, id),
         {:ok, socket} <- WorkspaceGuard.hold(socket, people.workspace.id, notify: true) do
      workspaces = WorkspaceSwitcher.list(user)

      {:ok,
       socket
       |> assign(
         workspaces: workspaces,
         # The switcher names the viewer's current workspace, as it does in
         # the app, whichever workspace's settings this page shows.
         current_workspace_id: current_id(user, workspaces),
         suggestions: [],
         invite_login: "",
         page_title: people.workspace.name,
         catalog: nil,
         refreshing: false,
         adding: nil,
         available: nil,
         attaching: nil
       )
       |> assign_people(people)
       |> load_catalog()
       |> refresh_if_stale()
       |> WorkspaceGitHub.load_available(people.workspace.id)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, RavixWeb.Error.from(:not_found, noun: "workspace").message)
         |> redirect(to: "/")}
    end
  end

  # `?github=connected` and `?github_error=...` are where the connect
  # round trip lands (`RavixWeb.WorkspaceGitHubController.finish/2`).
  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      cond do
        params["github"] == "connected" ->
          socket |> put_flash(:info, "GitHub connected.") |> load_catalog()

        is_binary(params["github_error"]) ->
          put_flash(socket, :error, WorkspaceGitHub.connect_error(params["github_error"]))

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("refresh-catalog", _params, socket), do: {:noreply, start_refresh(socket)}

  def handle_event("add-repo", %{"repo" => repo}, socket) do
    if socket.assigns.adding do
      {:noreply, socket}
    else
      user = socket.assigns.current_user
      id = workspace_id(socket)

      {:noreply,
       socket
       |> assign(adding: repo)
       |> start_async(:add_repo, fn -> Repositories.add(user, id, repo) end)}
    end
  end

  def handle_event("add-installation", %{"installation" => id}, socket),
    do: {:noreply, WorkspaceGitHub.add_installation(socket, workspace_id(socket), id)}

  @impl true
  def handle_event("workspace-create", %{"name" => name}, socket),
    do: {:noreply, WorkspaceSwitcher.create(socket, name)}

  # The switcher scopes the app, and this page is not the app: picking a
  # workspace here makes it current and goes back to its projects.
  def handle_event("workspace-select", %{"workspace" => id}, socket) do
    case WorkspaceSwitcher.select(socket, id) do
      {:ok, socket} -> {:noreply, push_navigate(socket, to: "/home")}
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("suggest", %{"login" => q}, socket) do
    suggestions = if manager?(socket), do: People.search(socket.assigns.current_user, q), else: []
    {:noreply, assign(socket, suggestions: suggestions, invite_login: q)}
  end

  def handle_event("invite", %{"login" => login} = params, socket) do
    case Workspaces.invite(
           socket.assigns.current_user,
           workspace_id(socket),
           login,
           params["role"] || "member"
         ) do
      {:ok, outcome} ->
        message =
          if outcome == :member,
            do: "Added @#{strip(login)} to #{socket.assigns.workspace.name}.",
            else: "Invited @#{strip(login)}. They join when they first sign in."

        {:noreply,
         socket
         |> assign(suggestions: [], invite_login: "")
         |> put_flash(:info, message)
         |> reload()}

      {:error, reason} ->
        {:noreply, socket |> assign(invite_login: login) |> refused(reason)}
    end
  end

  def handle_event("revoke-invite", %{"login" => login}, socket) do
    socket.assigns.current_user
    |> Workspaces.revoke_invite(workspace_id(socket), login)
    |> settled(socket, "Withdrew the invitation to @#{login}.")
  end

  def handle_event("remove-member", %{"user" => user_id, "login" => login}, socket) do
    socket.assigns.current_user
    |> Workspaces.remove_member(workspace_id(socket), user_id)
    |> settled(socket, "Removed @#{login}.")
  end

  def handle_event("set-role", %{"user" => user_id, "role" => role}, socket) do
    socket.assigns.current_user
    |> Workspaces.set_role(workspace_id(socket), user_id, role)
    |> settled(socket, "Role changed.")
  end

  # The guard passes the hub notice on only while the viewer is still a
  # member; see `WorkspaceGuard.hold/3`. A connection bound elsewhere
  # announces itself the same way.
  @impl true
  def handle_info({:workspace_hub, _id, :members}, socket),
    do:
      {:noreply,
       socket
       |> reload()
       |> load_catalog()
       |> WorkspaceGitHub.load_available(workspace_id(socket))}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The guard has re-read the membership before either result lands.
  @impl true
  def handle_async(:refresh, {:ok, result}, socket) do
    socket = assign(socket, refreshing: false) |> load_catalog()

    case result do
      {:ok, %{errors: [], collisions: []}} ->
        {:noreply, socket}

      {:ok, %{errors: errors, collisions: collisions}} ->
        {:noreply, put_flash(socket, :error, WorkspaceGitHub.refresh_problem(errors, collisions))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, RavixWeb.Error.from(reason).message)}
    end
  end

  def handle_async(:refresh, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(refreshing: false)
       |> put_flash(:error, "GitHub could not be read. Try Refresh again.")}

  def handle_async(:available, result, socket),
    do: {:noreply, WorkspaceGitHub.available_result(socket, result)}

  def handle_async(:add_installation, result, socket) do
    {:noreply,
     socket
     |> WorkspaceGitHub.installation_added(result)
     |> load_catalog()
     |> WorkspaceGitHub.load_available(workspace_id(socket))}
  end

  def handle_async(:add_repo, {:ok, {:ok, %{project: %{id: id}}}}, socket),
    do: {:noreply, socket |> assign(adding: nil) |> push_navigate(to: "/p/#{id}")}

  # Not a shape `Repositories.add/3` answers; drawn as a refusal, never a crash.
  def handle_async(:add_repo, {:ok, {:ok, _no_project}}, socket),
    do: handle_async(:add_repo, {:exit, :no_project}, socket)

  def handle_async(:add_repo, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(adding: nil)
     |> put_flash(:error, RavixWeb.Error.from(reason, noun: "repository").message)
     |> load_catalog()}
  end

  def handle_async(:add_repo, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(adding: nil)
       |> put_flash(:error, "The repository could not be added. Try again.")}

  defp load_catalog(socket) do
    case Repositories.catalog(socket.assigns.current_user, workspace_id(socket)) do
      {:ok, catalog} -> assign(socket, catalog: catalog)
      {:error, _} -> assign(socket, catalog: nil)
    end
  end

  # Only once connected, and only when there is a live connection whose
  # catalog is missing or older than `@stale_ms`: a page render never asks
  # GitHub itself.
  defp refresh_if_stale(socket) do
    catalog = socket.assigns.catalog

    stale? =
      catalog != nil and
        Enum.any?(catalog.installations, &(Installation.status(&1) == :active)) and
        (is_nil(catalog.refreshed_at) or
           DateTime.diff(DateTime.utc_now(), catalog.refreshed_at, :millisecond) > @stale_ms)

    if connected?(socket) and stale?, do: start_refresh(socket), else: socket
  end

  defp start_refresh(%{assigns: %{refreshing: true}} = socket), do: socket

  defp start_refresh(socket) do
    user = socket.assigns.current_user
    id = workspace_id(socket)

    socket
    |> assign(refreshing: true)
    |> start_async(:refresh, fn -> Repositories.refresh(user, id) end)
  end

  defp settled(:ok, socket, message),
    do: {:noreply, socket |> put_flash(:info, message) |> reload()}

  defp settled({:error, reason}, socket, _message), do: {:noreply, refused(socket, reason)}

  defp refused(socket, reason) do
    socket
    |> put_flash(:error, RavixWeb.Error.from(reason, noun: "workspace member").message)
    |> reload()
  end

  defp reload(socket) do
    case Workspaces.people(socket.assigns.current_user, workspace_id(socket)) do
      {:ok, people} -> assign_people(socket, people)
      {:error, :not_found} -> redirect(socket, to: "/")
    end
  end

  defp assign_people(socket, people) do
    assign(socket,
      workspace: people.workspace,
      role: people.role,
      members: people.members,
      invites: people.invites
    )
  end

  defp workspace_id(socket), do: socket.assigns.workspace_access.workspace.id

  defp current_id(user, workspaces) do
    case Workspaces.current(user, workspaces) do
      {:ok, %{workspace: workspace}} -> workspace.id
      {:error, :not_found} -> nil
    end
  end

  defp manager?(socket), do: Ravix.Accounts.Access.can?(socket.assigns.role, :manage_members)

  defp strip("@" <> login), do: String.trim(login)
  defp strip(login), do: String.trim(to_string(login))

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        manager?: Ravix.Accounts.Access.can?(assigns.role, :manage_members),
        owner?: Ravix.Accounts.Access.can?(assigns.role, :manage_roles),
        team?: assigns.workspace.kind == :team
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <main id="workspace-page" class="workspace-page">
        <header class="workspace-page-head">
          <WorkspaceSwitcher.switcher workspaces={@workspaces} current_id={@current_workspace_id} />
          <.link navigate="/home" class="ghost">Back to projects</.link>
        </header>

        <h1 id="workspace-title">{@workspace.name}</h1>
        <p class="hint">
          {if @team?, do: "Team workspace", else: "Personal workspace"} · your role: {role_label(
            @role
          )}
        </p>
        <p :if={!@team?} class="hint">
          A personal workspace is yours alone. Create a team workspace to invite people.
        </p>

        <section :if={@team? and @manager?} aria-labelledby="invite-heading">
          <h2 id="invite-heading">Invite by GitHub username</h2>
          <form id="workspace-invite-form" phx-submit="invite" phx-change="suggest">
            <label for="workspace-invite-login">GitHub username</label>
            <input
              id="workspace-invite-login"
              name="login"
              type="text"
              value={@invite_login}
              list="workspace-invite-suggestions"
              autocomplete="off"
              phx-debounce="200"
              required
            />
            <datalist id="workspace-invite-suggestions">
              <option :for={person <- @suggestions} value={person.login}>{person.name}</option>
            </datalist>
            <label for="workspace-invite-role">Role</label>
            <select id="workspace-invite-role" name="role">
              <option value="member">Member</option>
              <option :if={@owner?} value="admin">Admin</option>
              <option :if={@owner?} value="owner">Owner</option>
            </select>
            <button type="submit" class="primary">Invite</button>
          </form>
          <p class="hint">
            Somebody who has not signed in to Ravix yet joins when they first do.
          </p>
        </section>

        <section aria-labelledby="members-heading">
          <h2 id="members-heading">Members</h2>
          <ul id="workspace-members" class="workspace-people">
            <li :for={member <- @members} id={"member-#{member.user.id}"}>
              <img :if={member.user.avatar_url} src={member.user.avatar_url} alt="" class="avatar" />
              <span class="truncate">@{member.user.login}</span>
              <span class="spacer"></span>
              <form
                :if={@owner? and @team?}
                id={"role-#{member.user.id}"}
                phx-change="set-role"
              >
                <input type="hidden" name="user" value={member.user.id} />
                <select name="role" aria-label={"Role of @#{member.user.login}"}>
                  <option
                    :for={role <- [:owner, :admin, :member]}
                    value={role}
                    selected={role == member.role}
                  >
                    {role_label(role)}
                  </option>
                </select>
              </form>
              <small :if={!(@owner? and @team?)}>{role_label(member.role)}</small>
              <button
                :if={@manager? and @team? and member.user.id != @current_user.id}
                type="button"
                class="ghost"
                phx-click="remove-member"
                phx-value-user={member.user.id}
                phx-value-login={member.user.login}
                data-confirm={"Remove @#{member.user.login} from #{@workspace.name}?"}
              >
                Remove
              </button>
            </li>
          </ul>
        </section>

        <section :if={@team?} aria-labelledby="invites-heading">
          <h2 id="invites-heading">Invited</h2>
          <p :if={@invites == []} class="hint">Nobody is waiting to join.</p>
          <ul id="workspace-invites" class="workspace-people">
            <li :for={invite <- @invites} id={"invite-#{invite.login_key}"}>
              <span class="truncate">@{invite.login}</span>
              <span class="spacer"></span>
              <small>{role_label(invite.role)} · waiting to sign in</small>
              <button
                :if={@owner? or (@manager? and not Invite.protected?(invite))}
                type="button"
                class="ghost"
                phx-click="revoke-invite"
                phx-value-login={invite.login}
              >
                Revoke
              </button>
            </li>
          </ul>
        </section>
        <WorkspaceGitHub.section
          workspace={@workspace}
          role={@role}
          catalog={@catalog}
          refreshing={@refreshing}
          adding={@adding}
          available={@available}
          attaching={@attaching}
        />
      </main>
    </Layouts.app>
    """
  end

  defp role_label(:owner), do: "Owner"
  defp role_label(:admin), do: "Admin"
  defp role_label(:member), do: "Member"
end
