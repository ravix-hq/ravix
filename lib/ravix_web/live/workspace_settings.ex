defmodule RavixWeb.Live.WorkspaceSettings do
  @moduledoc """
  One workspace's settings, `/w/:workspace/settings/:section`, in the
  settings frame (`RavixWeb.Live.Settings`, RAV-72): General and Members.

  Members is what `/w/:workspace` was (ADR 0009, phases 4a and 4b), moved
  in unchanged: who is in the workspace, who is invited, the invite box,
  and its GitHub (`RavixWeb.Live.WorkspaceGitHub`) with RAV-69's "Add to
  workspace". Owners and admins invite by GitHub login, with suggestions
  from the people who have signed in here, withdraw waiting invitations and
  remove members; owners also change roles. Every one of those is decided
  again by the context; the page only hides the controls a role cannot use.

  General is the workspace's name, which owners and admins rename
  (`Ravix.Workspaces.rename/3`), and its kind, which nothing changes. It is
  the first page on the frame's one-Save model: an unsaved-changes bar and
  a confirmation before leaving.

  Behind `RAVIX_WORKSPACE_ACCESS`. `RavixWeb.WorkspaceLive` admits the URL
  (`Ravix.Accounts.Access.workspace_access/2`) before rendering this; the
  component reads the membership again on every event and every async
  result, and on the workspace's hub notice, which the page passes on as
  `reload: true`. A viewer who is no longer a member is sent home.
  """
  use RavixWeb, :live_component

  alias Ravix.Accounts.Access
  alias Ravix.{People, Workspaces}
  alias Ravix.Workspaces.{Installation, Invite, Repositories}
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
         catalog: nil,
         refreshing: false,
         adding: nil,
         available: nil,
         attaching: nil,
         saved: 0
       )}

  # The page moves this component to another workspace, with the section
  # kept, when the switcher is used here; everything is read again for it.
  @impl true
  def update(%{reload: true}, socket) do
    case Workspaces.people(socket.assigns.current_user, workspace_id(socket)) do
      {:ok, people} -> {:ok, socket |> assign_people(people) |> load_github()}
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
          catalog: nil,
          refreshing: false,
          adding: nil,
          available: nil,
          attaching: nil
        )
        |> assign_people(people)
        |> assign(general_form: general_form(people.workspace))
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

  defp workspace_event("suggest", %{"login" => q}, socket) do
    suggestions = if manager?(socket), do: People.search(socket.assigns.current_user, q), else: []
    {:noreply, assign(socket, suggestions: suggestions, invite_login: q)}
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
         |> assign(suggestions: [], invite_login: "")
         |> flash(:info, message)
         |> reload()}

      {:error, reason} ->
        {:noreply, socket |> assign(invite_login: login) |> refused(reason)}
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
      {:ok, people} -> assign_people(socket, people)
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

  defp strip("@" <> login), do: String.trim(login)
  defp strip(login), do: String.trim(to_string(login))

  @impl true
  def render(%{workspace: %{}} = assigns) do
    assigns =
      assign(assigns,
        manager?: Access.can?(assigns.role, :manage_members),
        owner?: Access.can?(assigns.role, :manage_roles),
        rename?: Access.can?(assigns.role, :rename_workspace),
        team?: assigns.workspace.kind == :team
      )

    ~H"""
    <div id="workspace-settings-content" class="workspace-settings">
      <Settings.frame
        kind={:workspace}
        section={@section}
        crumbs={[@workspace.name]}
        nav={[
          Settings.you_group(),
          Settings.workspace_group(@workspace, %{"members" => length(@members)})
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
        </div>

        <div :if={@section == "members"} id="workspace-page" class="workspace-page">
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
            <form
              id="workspace-invite-form"
              phx-submit="invite"
              phx-change="suggest"
              phx-target={@myself}
            >
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
                  phx-target={@myself}
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
            target={@myself}
          />
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
end
