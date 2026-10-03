defmodule RavixWeb.Live.WorkspaceSettings do
  @moduledoc """
  One workspace's settings, `/w/:workspace/settings/:section`, in the
  settings frame (`RavixWeb.Live.Settings`, RAV-72, RAV-73):

    * **General** -- the name, which owners and admins rename
      (`Ravix.Workspaces.rename/3`) on the frame's one-Save model, the kind,
      which nothing changes, and "New workspace…".
    * **Members** -- ADR 0009's one role list, Owner / Admin / Member, with
      a line on what each may do; who is in the workspace; invite by GitHub
      login with a role (owners offer all three, admins Member); and the
      invitations still waiting. Owners change roles.
    * **Repositories** -- its GitHub (`RavixWeb.Live.WorkspaceGitHub`):
      the connected accounts, RAV-69's "Add to workspace", each repository
      with the project that uses it, "Configure on GitHub" and Refresh.
    * **Projects** -- every project in it, with its owner, repository,
      agent and how many people reach it.
    * **Danger zone** -- leave it (`Ravix.Workspaces.leave/2`), and, for
      owners, delete it with its name typed (`Ravix.Workspaces.delete/3`).

  Every action is decided again by the context; the page only hides the
  controls a role cannot use.

  Behind `RAVIX_WORKSPACE_ACCESS`. `RavixWeb.WorkspaceLive` admits the URL
  (`Ravix.Accounts.Access.workspace_access/2`) before rendering this; the
  component reads the membership again on every event and every async
  result, and on the workspace's hub notice, which the page passes on as
  `reload: true`. A viewer who is no longer a member is sent home.
  """
  use RavixWeb, :live_component

  alias Ravix.Accounts.Access
  alias Ravix.{People, Workspaces}
  alias Ravix.Workspaces.{Connect, Installation, Invite, Repositories}
  alias RavixWeb.Live.{Form, Settings, WorkspaceGitHub}

  # How old the catalog may be before opening the page refreshes it.
  @stale_ms 10 * 60 * 1000

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         loaded: nil,
         suggestions: [],
         invite_login: "",
         invite_role: "member",
         catalog: nil,
         refreshing: false,
         adding: nil,
         available: nil,
         attaching: nil,
         projects: [],
         configure_url: nil,
         delete_confirm: "",
         saved: 0
       )}

  # The page moves this component to another workspace, with the section
  # kept, when the switcher is used here; everything is read again for it.
  @impl true
  def update(%{reload: true}, socket) do
    case Workspaces.people(socket.assigns.current_user, workspace_id(socket)) do
      {:ok, people} -> {:ok, socket |> assign_people(people) |> load_projects() |> load_github()}
      {:error, :not_found} -> {:ok, assign(socket, workspace: nil)}
    end
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns.loaded == socket.assigns.workspace_id,
      do: {:ok, socket},
      else: {:ok, load(socket)}
  end

  defp load(socket) do
    case Workspaces.people(socket.assigns.current_user, socket.assigns.workspace_id) do
      {:ok, people} ->
        socket
        |> assign(
          loaded: people.workspace.id,
          suggestions: [],
          invite_login: "",
          invite_role: "member",
          catalog: nil,
          refreshing: false,
          adding: nil,
          available: nil,
          attaching: nil,
          delete_confirm: ""
        )
        |> assign_people(people)
        |> assign(general_form: general_form(people.workspace))
        |> assign(configure_url: configure_url(socket.assigns.current_user, people.workspace.id))
        |> load_projects()
        |> load_github()
        |> refresh_if_stale()

      # `update/2` cannot redirect; the page, which admitted the URL, is
      # the one that leaves (`RavixWeb.WorkspaceLive`'s members notice).
      {:error, :not_found} ->
        assign(socket, workspace: nil)
    end
  end

  defp load_github(%{assigns: %{workspace: %{id: id}}} = socket),
    do: socket |> load_catalog() |> WorkspaceGitHub.load_available(id)

  defp load_github(socket), do: socket

  defp load_projects(%{assigns: %{workspace: %{id: id}}} = socket) do
    case Workspaces.projects(socket.assigns.current_user, id) do
      {:ok, projects} -> assign(socket, projects: projects)
      {:error, :not_found} -> assign(socket, projects: [])
    end
  end

  defp load_projects(socket), do: socket

  # Only for a role that may change the connections; nil otherwise, and
  # without a GitHub App to point at.
  defp configure_url(user, workspace_id) do
    case Connect.configure_url(user, workspace_id) do
      {:ok, url} -> url
      {:error, _} -> nil
    end
  end

  @impl true
  def handle_event(event, params, socket) do
    case Access.workspace_access(socket.assigns.current_user, workspace_id(socket)) do
      {:ok, _access} -> workspace_event(event, params, socket)
      {:error, :not_found} -> {:noreply, gone(socket)}
    end
  end

  defp workspace_event("rename", %{"workspace" => %{"name" => name} = params}, socket) do
    {:noreply,
     result(
       assign(socket, general_form: Form.new(:workspace, params)),
       Workspaces.rename(socket.assigns.current_user, workspace_id(socket), name),
       fn s, workspace ->
         s
         |> assign(workspace: workspace, general_form: general_form(workspace))
         |> update(:saved, &(&1 + 1))
         |> flash(:info, "Workspace renamed.")
       end,
       :general_form
     )}
  end

  defp workspace_event("discard-general", _params, socket),
    do: {:noreply, assign(socket, general_form: general_form(socket.assigns.workspace))}

  defp workspace_event("refresh-catalog", _params, socket),
    do: {:noreply, start_refresh(socket)}

  defp workspace_event("add-repo", %{"repo" => repo}, socket) do
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

  defp workspace_event("add-installation", %{"installation" => id}, socket),
    do: {:noreply, WorkspaceGitHub.add_installation(socket, workspace_id(socket), id)}

  # The role is kept as it is chosen, so the redraw this answers with
  # does not put the select back to Member.
  defp workspace_event("suggest", %{"login" => q} = params, socket) do
    suggestions = if manager?(socket), do: People.search(socket.assigns.current_user, q), else: []

    {:noreply,
     assign(socket,
       suggestions: suggestions,
       invite_login: q,
       invite_role: invite_role(params["role"])
     )}
  end

  defp workspace_event("invite", %{"login" => login} = params, socket) do
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
         |> assign(suggestions: [], invite_login: "", invite_role: "member")
         |> flash(:info, message)
         |> reload()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(invite_login: login, invite_role: invite_role(params["role"]))
         |> refused(reason)}
    end
  end

  defp workspace_event("revoke-invite", %{"login" => login}, socket) do
    socket.assigns.current_user
    |> Workspaces.revoke_invite(workspace_id(socket), login)
    |> settled(socket, "Withdrew the invitation to @#{login}.")
  end

  defp workspace_event("remove-member", %{"user" => user_id, "login" => login}, socket) do
    socket.assigns.current_user
    |> Workspaces.remove_member(workspace_id(socket), user_id)
    |> settled(socket, "Removed @#{login}.")
  end

  defp workspace_event("set-role", %{"user" => user_id, "role" => role}, socket) do
    socket.assigns.current_user
    |> Workspaces.set_role(workspace_id(socket), user_id, role)
    |> settled(socket, "Role changed.")
  end

  defp workspace_event("leave", _params, socket) do
    name = socket.assigns.workspace.name

    case Workspaces.leave(socket.assigns.current_user, workspace_id(socket)) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "You left #{name}.") |> push_navigate(to: "/home")}

      {:error, reason} ->
        {:noreply, error(socket, reason)}
    end
  end

  defp workspace_event("delete-confirm", %{"confirm" => typed}, socket),
    do: {:noreply, assign(socket, delete_confirm: typed)}

  defp workspace_event("delete", %{"confirm" => typed}, socket) do
    name = socket.assigns.workspace.name

    case Workspaces.delete(socket.assigns.current_user, workspace_id(socket), typed) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Deleted #{name}.") |> push_navigate(to: "/home")}

      {:error, reason} ->
        {:noreply, socket |> assign(delete_confirm: typed) |> error(reason)}
    end
  end

  # Work started while somebody was a member must not render once they are
  # not, even when its answer beats the removal notice to the page.
  @impl true
  def handle_async(name, result, socket) do
    case Access.workspace_access(socket.assigns.current_user, workspace_id(socket)) do
      {:ok, _access} -> async_result(name, result, socket)
      {:error, :not_found} -> {:noreply, gone(socket)}
    end
  end

  defp async_result(:refresh, {:ok, result}, socket) do
    socket = assign(socket, refreshing: false) |> load_catalog()

    case result do
      {:ok, %{errors: [], collisions: []}} ->
        {:noreply, socket}

      {:ok, %{errors: errors, collisions: collisions}} ->
        {:noreply, flash(socket, :error, WorkspaceGitHub.refresh_problem(errors, collisions))}

      {:error, reason} ->
        {:noreply, error(socket, reason)}
    end
  end

  defp async_result(:refresh, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(refreshing: false)
       |> flash(:error, "GitHub could not be read. Try Refresh again.")}

  defp async_result(:available, result, socket),
    do: {:noreply, WorkspaceGitHub.available_result(socket, result)}

  defp async_result(:add_installation, result, socket) do
    {:noreply,
     socket
     |> WorkspaceGitHub.installation_added(result)
     |> load_github()}
  end

  defp async_result(:add_repo, {:ok, {:ok, %{project: %{id: id}}}}, socket),
    do: {:noreply, socket |> assign(adding: nil) |> push_navigate(to: "/p/#{id}")}

  # Not a shape `Repositories.add/3` answers; drawn as a refusal, never a crash.
  defp async_result(:add_repo, {:ok, {:ok, _no_project}}, socket),
    do: async_result(:add_repo, {:exit, :no_project}, socket)

  defp async_result(:add_repo, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(adding: nil)
     |> flash(:error, RavixWeb.Error.from(reason, noun: "repository").message)
     |> load_catalog()}
  end

  defp async_result(:add_repo, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(adding: nil)
       |> flash(:error, "The repository could not be added. Try again.")}

  defp load_catalog(socket) do
    case Repositories.catalog(socket.assigns.current_user, workspace_id(socket)) do
      {:ok, catalog} -> assign(socket, catalog: catalog)
      {:error, _} -> assign(socket, catalog: nil)
    end
  end

  # Only once connected, and only when there is a live connection whose
  # catalog is missing or older than `@stale_ms`: a page render never asks
  # GitHub itself.
  defp refresh_if_stale(%{assigns: %{catalog: catalog}} = socket) when not is_nil(catalog) do
    stale? =
      Enum.any?(catalog.installations, &(Installation.status(&1) == :active)) and
        (is_nil(catalog.refreshed_at) or
           DateTime.diff(DateTime.utc_now(), catalog.refreshed_at, :millisecond) > @stale_ms)

    if connected?(socket) and stale?, do: start_refresh(socket), else: socket
  end

  defp refresh_if_stale(socket), do: socket

  defp start_refresh(%{assigns: %{refreshing: true}} = socket), do: socket

  defp start_refresh(socket) do
    user = socket.assigns.current_user
    id = workspace_id(socket)

    socket
    |> assign(refreshing: true)
    |> start_async(:refresh, fn -> Repositories.refresh(user, id) end)
  end

  defp settled(:ok, socket, message),
    do: {:noreply, socket |> flash(:info, message) |> reload()}

  defp settled({:error, reason}, socket, _message), do: {:noreply, refused(socket, reason)}

  defp refused(socket, reason) do
    socket
    |> flash(:error, RavixWeb.Error.from(reason, noun: "workspace member").message)
    |> reload()
  end

  defp reload(socket) do
    case Workspaces.people(socket.assigns.current_user, workspace_id(socket)) do
      {:ok, people} -> socket |> assign_people(people) |> load_projects()
      {:error, :not_found} -> gone(socket)
    end
  end

  # A rename elsewhere redraws the name here, but never over one being typed:
  # the form is only rebuilt when nothing has been submitted into it.
  defp assign_people(socket, people) do
    socket
    |> assign(
      workspace: people.workspace,
      role: people.role,
      members: people.members,
      invites: people.invites
    )
    |> assign_new(:general_form, fn -> general_form(people.workspace) end)
  end

  defp general_form(workspace), do: Form.new(:workspace, %{"name" => workspace.name})

  defp gone(socket), do: redirect(socket, to: "/")

  defp workspace_id(socket), do: socket.assigns[:loaded] || socket.assigns.workspace_id

  defp manager?(socket), do: Access.can?(socket.assigns.role, :manage_members)

  defp invite_role(role) when role in ~w(owner admin member), do: role
  defp invite_role(_role), do: "member"

  defp strip("@" <> login), do: String.trim(login)
  defp strip(login), do: String.trim(to_string(login))

  @impl true
  def render(%{workspace: %{}} = assigns) do
    assigns =
      assign(assigns,
        manager?: Access.can?(assigns.role, :manage_members),
        owner?: Access.can?(assigns.role, :manage_roles),
        rename?: Access.can?(assigns.role, :rename_workspace),
        delete?: Access.can?(assigns.role, :delete_workspace),
        team?: assigns.workspace.kind == :team,
        own_personal?: assigns.workspace.personal_user_id == assigns.current_user.id
      )

    ~H"""
    <div id="workspace-settings-content" class="settings-host">
      <Settings.frame
        kind={:workspace}
        section={@section}
        crumbs={[@workspace.name]}
        nav={[
          Settings.you_group()
          | Settings.workspace_groups(@workspace, %{
              "members" => length(@members),
              "repositories" => @catalog && length(@catalog.repos),
              "projects" => length(@projects)
            })
        ]}
      >
        <div :if={@section == "general"} id="workspace-general" class="workspace-page">
          <Settings.unsaved_changes
            :if={@rename?}
            id="workspace-general-unsaved"
            form="workspace-general-form"
            saved={@saved}
            discard="discard-general"
            target={@myself}
          >
            <.form
              for={@general_form}
              id="workspace-general-form"
              phx-submit="rename"
              phx-target={@myself}
            >
              <.input
                field={@general_form[:name]}
                id="workspace-name"
                label="Name"
                maxlength="60"
                autocomplete="off"
                required
              />
            </.form>
          </Settings.unsaved_changes>
          <dl class="workspace-facts">
            <div :if={!@rename?}>
              <dt>Name</dt>
              <dd id="workspace-name-shown">{@workspace.name}</dd>
            </div>
            <div>
              <dt>Kind</dt>
              <dd id="workspace-kind">
                {if @team?, do: "Team workspace", else: "Personal workspace"}
              </dd>
            </div>
            <div>
              <dt>Your role</dt>
              <dd>{role_label(@role)}</dd>
            </div>
          </dl>
          <p :if={!@team?} class="hint">
            A personal workspace is yours alone. Create a team workspace to invite people.
          </p>
          <section aria-labelledby="new-workspace-heading">
            <h2 id="new-workspace-heading">Another workspace</h2>
            <p class="hint">A team workspace has its own members, repositories and projects.</p>
            <button
              type="button"
              id="general-new-workspace"
              class="ghost"
              phx-click="dialog"
              phx-value-name="new-workspace"
            >
              <.icon name="plus" size={14} />New workspace…
            </button>
          </section>
        </div>

        <div :if={@section == "members"} id="workspace-page" class="workspace-page">
          <p :if={!@team?} class="hint">
            A personal workspace is yours alone. Create a team workspace to invite people.
          </p>

          <section aria-labelledby="roles-heading">
            <h2 id="roles-heading">Roles</h2>
            <dl id="workspace-roles" class="workspace-roles">
              <div :for={role <- [:owner, :admin, :member]} data-role={role}>
                <dt>{role_label(role)}</dt>
                <dd>{role_line(role)}</dd>
              </div>
            </dl>
            <p class="hint">
              Every member can work in every project here. A project can give somebody a different role;
              the project's People list shows where each person's access comes from.
            </p>
          </section>

          <section :if={@team? and @manager?} aria-labelledby="invite-heading">
            <h2 id="invite-heading">Invite by GitHub username</h2>
            <form
              id="workspace-invite-form"
              class="workspace-invite"
              phx-submit="invite"
              phx-change="suggest"
              phx-target={@myself}
            >
              <div class="field">
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
              </div>
              <div class="field">
                <label for="workspace-invite-role">Role</label>
                <select id="workspace-invite-role" name="role">
                  <option
                    :for={role <- if(@owner?, do: [:member, :admin, :owner], else: [:member])}
                    value={role}
                    selected={to_string(role) == @invite_role}
                  >
                    {role_label(role)}
                  </option>
                </select>
              </div>
              <button type="submit" class="primary">Invite</button>
            </form>
            <p class="hint">
              Somebody who has not signed in to Ravix yet joins when they first do.
              <span :if={!@owner?}>Only an owner can invite an admin or owner.</span>
            </p>
          </section>

          <section aria-labelledby="members-heading">
            <h2 id="members-heading">Members</h2>
            <ul id="workspace-members" class="workspace-people">
              <li :for={member <- @members} id={"member-#{member.user.id}"}>
                <img
                  :if={member.user.avatar_url}
                  src={member.user.avatar_url}
                  alt=""
                  class="avatar"
                  width="24"
                  height="24"
                />
                <span class="truncate">@{member.user.login}</span>
                <small :if={member.user.id == @current_user.id}>you</small>
                <span class="spacer"></span>
                <form
                  :if={@owner? and @team?}
                  id={"role-#{member.user.id}"}
                  phx-change="set-role"
                  phx-target={@myself}
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
                  phx-target={@myself}
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
            <h2 id="invites-heading">Pending invitations</h2>
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
                  phx-target={@myself}
                  phx-value-login={invite.login}
                >
                  Revoke
                </button>
              </li>
            </ul>
          </section>
        </div>

        <div :if={@section == "repositories"} id="workspace-repositories-page" class="workspace-page">
          <WorkspaceGitHub.section
            workspace={@workspace}
            role={@role}
            catalog={@catalog}
            refreshing={@refreshing}
            adding={@adding}
            available={@available}
            attaching={@attaching}
            configure_url={@configure_url}
            target={@myself}
          />
        </div>

        <div :if={@section == "projects"} id="workspace-projects-page" class="workspace-page">
          <p :if={@projects == []} id="workspace-projects-empty" class="hint">
            No projects yet. Add one from <.link patch={
              Settings.section_path(:workspace, @workspace.id, "repositories")
            }>
              Repositories
            </.link>.
          </p>
          <table :if={@projects != []} id="workspace-projects" class="workspace-projects">
            <thead>
              <tr>
                <th scope="col">Project</th>
                <th scope="col">Owner</th>
                <th scope="col">Repository</th>
                <th scope="col">Agent</th>
                <th scope="col">People</th>
                <th scope="col"><span class="sr-only">Settings</span></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={%{project: project, owner: owner, people: people} <- @projects}
                id={"workspace-project-#{project.id}"}
              >
                <th scope="row">
                  <.link navigate={"/p/#{project.id}"}>{project.name}</.link>
                </th>
                <td>@{owner.login}</td>
                <td>
                  <span :if={project.repo_full_name}>{project.repo_full_name}</span>
                  <span :if={!project.repo_full_name} class="hint">No repository</span>
                </td>
                <td>{Ravix.AgentName.label(project.runtime || "claude")}</td>
                <td>{people}</td>
                <td>
                  <.link
                    :if={project.user_id == @current_user.id}
                    navigate={Settings.section_path(:project, project.id, "general")}
                    class="ghost"
                    aria-label={"Settings of #{project.name}"}
                    data-tip={"Settings of #{project.name}"}
                  >
                    <.icon name="settings" size={14} />
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@section == "danger"} id="workspace-danger" class="workspace-page">
          <section class="danger-card" aria-labelledby="leave-heading">
            <h2 id="leave-heading">Leave this workspace</h2>
            <p :if={@own_personal?} class="hint">
              This is your personal workspace. You cannot leave it.
            </p>
            <p :if={!@own_personal?} class="hint">
              You lose access to its projects and tracks unless somebody shared them with you directly.
              An owner or admin can invite you back.
            </p>
            <button
              :if={!@own_personal?}
              type="button"
              id="leave-workspace"
              class="danger"
              phx-click="leave"
              phx-target={@myself}
              data-confirm={"Leave #{@workspace.name}?"}
            >
              Leave {@workspace.name}
            </button>
          </section>

          <section :if={@delete? and @team?} class="danger-card" aria-labelledby="delete-heading">
            <h2 id="delete-heading">Delete this workspace</h2>
            <p class="hint">
              Nobody can open it again, and its members, invitations and GitHub connections go with it.
            </p>
            <p :if={@projects != []} class="hint" id="delete-has-projects">
              It still has {length(@projects)} {if length(@projects) == 1,
                do: "project",
                else: "projects"}. Move or delete them first.
            </p>
            <form
              id="delete-workspace-form"
              phx-change="delete-confirm"
              phx-submit="delete"
              phx-target={@myself}
            >
              <label for="delete-workspace-confirm">
                Type <strong>{@workspace.name}</strong> to confirm
              </label>
              <input
                id="delete-workspace-confirm"
                name="confirm"
                type="text"
                value={@delete_confirm}
                autocomplete="off"
              />
              <button
                type="submit"
                class="danger"
                disabled={String.trim(@delete_confirm) != @workspace.name or @projects != []}
              >
                Delete {@workspace.name}
              </button>
            </form>
          </section>
          <p :if={!@delete? and @team?} class="hint" id="delete-owner-only">
            Only an owner can delete this workspace.
          </p>
        </div>
      </Settings.frame>
    </div>
    """
  end

  # Not a member (any more): the page is on its way home.
  # (Also the first render, before `update/2` has read anything.)
  def render(assigns), do: ~H(<div id="workspace-settings-content"></div>)

  defp role_label(:owner), do: "Owner"
  defp role_label(:admin), do: "Admin"
  defp role_label(:member), do: "Member"

  defp role_line(:owner),
    do:
      "Everything an admin can, and changes roles, adds GitHub accounts and deletes the workspace."

  defp role_line(:admin),
    do:
      "Invites and removes members, renames the workspace, connects repositories and adds projects."

  defp role_line(:member), do: "Works in every project here and starts tracks."
end
