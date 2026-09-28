defmodule RavixWeb.WorkspacePeopleLive do
  @moduledoc """
  One workspace's page: who is in it, who is invited, and the invite box
  (ADR 0009, phase 4a). Where the sidebar's workspace switcher goes.

  Behind `RAVIX_WORKSPACE_ACCESS`: with the switch off every workspace is
  not found here, as `Ravix.Workspaces.people/2` answers. The page holds its
  workspace through `RavixWeb.Live.WorkspaceGuard`, so a member removed
  while it is open is sent home on the next event, patch, async result or
  hub notice, and redraws the lists on the notice otherwise.

  Owners and admins invite by GitHub login, with suggestions from the
  people who have signed in here, withdraw waiting invitations and remove
  members; owners also change roles. Every one of those is decided again by
  the context; the page only hides the controls a role cannot use.
  """
  use RavixWeb, :live_view

  alias Ravix.{Accounts, People, Workspaces}
  alias Ravix.Workspaces.Invite
  alias RavixWeb.Live.{WorkspaceGuard, WorkspaceSwitcher}

  @impl true
  def mount(%{"workspace" => id}, _session, socket) do
    user = socket.assigns[:current_user]

    with %Accounts.User{} <- user,
         {:ok, people} <- Workspaces.people(user, id),
         {:ok, socket} <- WorkspaceGuard.hold(socket, people.workspace.id, notify: true) do
      {:ok,
       socket
       |> assign(
         workspaces: WorkspaceSwitcher.list(user),
         suggestions: [],
         invite_login: "",
         page_title: people.workspace.name
       )
       |> assign_people(people)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, RavixWeb.Error.from(:not_found, noun: "workspace").message)
         |> redirect(to: "/")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("workspace-create", %{"name" => name}, socket),
    do: {:noreply, WorkspaceSwitcher.create(socket, name)}

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
  # member; see `WorkspaceGuard.hold/3`.
  @impl true
  def handle_info({:workspace_hub, _id, :members}, socket), do: {:noreply, reload(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

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
          <WorkspaceSwitcher.switcher workspaces={@workspaces} current_id={@workspace.id} />
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
      </main>
    </Layouts.app>
    """
  end

  defp role_label(:owner), do: "Owner"
  defp role_label(:admin), do: "Admin"
  defp role_label(:member), do: "Member"
end
