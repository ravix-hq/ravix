defmodule RavixWeb.Live.PeopleDialog do
  @moduledoc """
  Who else is in this, and how to let somebody else in.

  One dialog for both units of sharing. The track page and the project page
  each had their own copy -- the same list, the same invite form, the same
  two buttons -- differing in a title, an id, and which of `Ravix.People`'s
  twinned functions they called. Kept apart they had already drifted: the
  same button read "Revoke link" on one page and "Revoke invite link" on the
  other until they were merged.

  It is a `live_component` rather than a function component because the
  dialog owns state neither page has any other use for: who is in the list
  right now, and the invite link in the one moment it can be shown. Both
  pages carried those as top-level assigns, which is how `WorkspaceLive`
  came to hold twenty-eight of them.

  `scope` picks the unit. What that changes is real and the dialog says so:
  a project member reaches project-visible tracks; private invitations remain
  separate, including when the person leaves the project.

  On a workspace project (`Ravix.People.workspace_sharing?/1`, RAV-32) the
  project scope lists who is in it and lets them be removed, but offers no
  invitation and no link: people join the workspace from its members page,
  linked only for somebody who can open it, and a track is shared from its
  Share dialog. `Ravix.People` refuses both
  as well, so hiding them here is the courtesy rather than the boundary.

  Roles (ADR 0010): each person named on this unit shows a role, Read,
  Write or Admin, and an admin changes it or removes their access from a
  menu beside them. Whether the caller is an admin is read here, through
  `Ravix.Accounts.Access`, and again whenever the page hears the people
  changed; `Ravix.People` checks it again on every change regardless. The
  copy link at the bottom is the track's (or project's) own address, for
  anybody in the dialog: it opens only for people who already have access,
  and is never an invitation.
  """
  use RavixWeb, :live_component

  alias Ravix.Accounts.Access
  alias Ravix.{People, Workspaces}
  alias Ravix.People.Person

  @roles [
    {"read", "Read", "See the transcript and preview"},
    {"write", "Write", "Also send prompts and use the machine"},
    {"admin", "Admin", "Also manage people"}
  ]

  @doc "The two units of sharing, and everything that differs between them."
  @spec scopes() :: [:track | :project]
  def scopes, do: [:track, :project]

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         invite: nil,
         inviting?: false,
         login: "",
         workspace_link?: false,
         admin?: false,
         url: nil
       )}

  @impl true
  # The page heard that the people changed: somebody's role, or the
  # caller's own, may be different now.
  def update(%{reload: true}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    socket = assign(socket, workspace_project?: workspace_project?(socket.assigns))

    # Unlike `invite: nil` above, this one is not a default `mount/1` could
    # have set: listing people needs the scope and the signed-in user, and
    # those arrive with the parent's assigns. It stays a guard on the assign
    # the load writes, which also means a refused load --- `result/3` leaves
    # the socket untouched --- is retried on the next update rather than
    # leaving the dialog permanently empty.
    {:ok, if(socket.assigns[:people], do: socket, else: load(socket))}
  end

  # Inviting somebody asks GitHub who they are, and a component runs in its
  # page's process, so the page stopped drawing and answering for as long as
  # GitHub took. The button is disabled until the answer lands, which is
  # also what stops a second Enter inviting them twice.
  @impl true
  def handle_event("visibility", %{"visibility" => visibility}, socket) do
    %{current_user: user, subject_id: id} = socket.assigns

    {:noreply,
     result(socket, Ravix.Tracks.set_visibility(user, id, visibility), fn s, value ->
       s |> assign(track: %{s.assigns.track | visibility: value}) |> load()
     end)}
  end

  # What has been typed into the invite box, held here rather than only in
  # the browser. The box sits inside the track page, which re-renders on
  # every change to the track -- setup progress, a rename, a turn -- and an
  # input the server does not know the value of is redrawn empty once it has
  # lost focus: a login typed and then left for the Invite button was gone
  # by the time the button was pressed.
  def handle_event("type-login", %{"login" => login}, socket),
    do: {:noreply, assign(socket, login: login)}

  def handle_event("invite-person", %{"login" => login}, socket) do
    %{scope: scope, subject_id: id, current_user: user} = socket.assigns

    {:noreply,
     socket
     |> assign(inviting?: true, login: login)
     |> traced_async(:invite, fn -> add(scope, user, id, login) end)}
  end

  def handle_event("remove-person", %{"login" => login}, socket) do
    %{scope: scope, subject_id: id, current_user: user} = socket.assigns

    {:noreply,
     result(socket, remove(scope, user, id, login), fn s, _ ->
       # Where to go afterwards is the page's business, not the dialog's, and
       # the two pages answer differently: the track page moves you only when
       # you removed yourself, the workspace re-reads the rail either way.
       send(self(), {:person_removed, scope, login})
       result(s, list(scope, user, id), &assign(&1, people: &2))
     end)}
  end

  def handle_event("set-role", %{"login" => login, "role" => role}, socket) do
    %{scope: scope, subject_id: id, current_user: user} = socket.assigns

    {:noreply, result(socket, set_role(scope, user, id, login, role), &assign(&1, people: &2))}
  end

  def handle_event("invite-link", %{"action" => action}, socket) do
    %{scope: scope, subject_id: id, current_user: user} = socket.assigns
    minting? = action == "create"

    response = if minting?, do: mint(scope, user, id), else: drop(scope, user, id)

    {:noreply,
     result(socket, response, fn s, value ->
       assign(s, invite: if(minting?, do: value, else: nil))
     end)}
  end

  @impl true
  # A refused invitation keeps what was typed, to be corrected; a sent one
  # empties the box for the next.
  def handle_async(:invite, {:ok, response}, socket),
    do:
      {:noreply,
       result(assign(socket, inviting?: false), response, &assign(&1, people: &2, login: ""))}

  def handle_async(:invite, {:exit, reason}, socket),
    do: {:noreply, socket |> assign(inviting?: false) |> exit(reason)}

  defp load(socket) do
    %{scope: scope, subject_id: id, current_user: user} = socket.assigns

    socket =
      socket
      |> result(list(scope, user, id), &assign(&1, people: &2))
      |> assign(workspace_link?: workspace_link?(socket.assigns), admin?: admin?(scope, user, id))
      |> result(copy_url(scope, user, id), &assign(&1, url: &2))

    if socket.assigns.admin? and not socket.assigns.workspace_project?,
      do: result(socket, link(scope, user, id), &assign(&1, invite: &2)),
      else: socket
  end

  defp admin?(:track, user, id), do: match?({:ok, _}, Access.track_access(user, id, :admin))
  defp admin?(:project, user, id), do: match?({:ok, _}, Access.project_access(user, id, :admin))

  defp copy_url(:track, user, id), do: People.track_url(user, id)
  defp copy_url(:project, user, id), do: People.project_url(user, id)

  defp set_role(:track, user, id, login, role), do: People.set_role(user, id, login, role)

  defp set_role(:project, user, id, login, role),
    do: People.set_project_role(user, id, login, role)

  defp list(:track, user, id), do: People.list(user, id)
  defp list(:project, user, id), do: People.list_project(user, id)

  defp add(:track, user, id, login), do: People.add(user, id, login)
  defp add(:project, user, id, login), do: People.add_project(user, id, login)

  defp remove(:track, user, id, login), do: People.remove(user, id, login)
  defp remove(:project, user, id, login), do: People.remove_project(user, id, login)

  defp link(:track, user, id), do: People.link(user, id)
  defp link(:project, user, id), do: People.project_link(user, id)

  defp mint(:track, user, id), do: People.mint_link(user, id)
  defp mint(:project, user, id), do: People.mint_project_link(user, id)

  defp drop(:track, user, id), do: People.drop_link(user, id)
  defp drop(:project, user, id), do: People.drop_project_link(user, id)

  # Only the project scope asks: the track page shows the Share dialog in
  # this one's place on a workspace project.
  defp workspace_project?(%{scope: :project, project: project}),
    do: People.workspace_sharing?(project)

  defp workspace_project?(_assigns), do: false

  # A legacy project member need not belong to the project's workspace, and
  # its members page answers them not found; the link is only for somebody
  # the page will open for.
  defp workspace_link?(%{workspace_project?: true, project: project, current_user: user}),
    do: match?({:ok, _}, Workspaces.get(user, project.workspace_id))

  defp workspace_link?(_assigns), do: false

  defp title(:track), do: "Track people"
  defp title(:project), do: "Project people"

  defp leave_label(:track), do: "Leave"
  defp leave_label(:project), do: "Leave project"

  @doc """
  Why this person is in this list, when that is not what the dialog is about.

  A track's list holds people who were never named on the track: its owner,
  and anybody let into the whole project. Without this, the owner reads a
  name they do not remember inviting to this branch and has no way to tell
  where it came from -- which is alarming, and is the thing `via` was being
  computed for long before anything displayed it.

  The project's own dialog says nothing for its own members, because there
  the answer is "they are project members" and the dialog already said so.
  """
  @spec badge(Person.t(), :track | :project) :: String.t() | nil
  def badge(%Person{via: :creator}, _scope), do: "creator"
  def badge(%Person{via: :owner}, _scope), do: "owner"
  def badge(%Person{via: :pending}, _scope), do: "invited, not signed in yet"
  def badge(%Person{via: :project}, :track), do: "in the whole project"
  def badge(%Person{via: :workspace}, _scope), do: "in the workspace"
  def badge(%Person{via: :shared}, _scope), do: "shared with them"
  def badge(%Person{}, _scope), do: nil

  # A control that cannot work is worse than no control. The owner holds the
  # project and cannot be removed from it or from a track on it; somebody
  # whose access comes from the project cannot be taken off one of its tracks
  # -- `Ravix.People.remove/3` refuses both, and the badge beside them now
  # says where to go instead.
  defp removable?(%Person{via: :creator}, _scope, _admin?, _user), do: false
  defp removable?(%Person{via: :owner}, _scope, _admin?, _user), do: false
  defp removable?(%Person{via: :project}, :track, _admin?, _user), do: false
  defp removable?(%Person{via: :workspace}, _scope, _admin?, _user), do: false
  defp removable?(%Person{via: :shared}, _scope, _admin?, _user), do: false

  defp removable?(%Person{} = person, _scope, admin?, user),
    do: admin? or person.login == user.login

  # Whose role this dialog changes: somebody named on this unit, and not
  # the caller. Everybody else's role is shown and changed where it lives.
  defp role_editable?(%Person{via: :track}, :track, true, _user), do: true
  defp role_editable?(%Person{via: :project}, :project, true, _user), do: true
  defp role_editable?(_person, _scope, _admin?, _user), do: false

  defp editable?(person, scope, admin?, user),
    do: role_editable?(person, scope, admin?, user) and person.login != user.login

  @doc "The label a role is shown with."
  @spec role_label(Person.role() | nil) :: String.t() | nil
  def role_label(:read), do: "Read"
  def role_label(:write), do: "Write"
  def role_label(:admin), do: "Admin"
  def role_label(nil), do: nil

  defp roles, do: @roles

  # Popover ids and anchor names come from a login, which GitHub limits to
  # letters, digits and hyphens.
  defp menu_id(id, login), do: "#{id}-role-menu-#{login}"

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.dialog id={"#{@id}-dialog"} title={title(@scope)} on_close="dismiss">
        <p><.project_name project={@project} /></p>
        <p :if={@scope == :project && !@workspace_project?} class="hint">
          Members can create tracks and work in tracks shared with this project. Private tracks require an invitation.
        </p>
        <form
          :if={@scope == :track && Ravix.Accounts.Access.creator?(@current_user, @track)}
          id="track-visibility-form"
          phx-change="visibility"
          phx-target={@myself}
        >
          <.input
            type="select"
            name="visibility"
            label="Sharing"
            value={@track.visibility}
            options={
              [{"Everyone in this project", :project}] ++
                if(@track.sandbox_layout == :dedicated,
                  do: [{"Only people I invite", :private}],
                  else: []
                )
            }
          />
          <p :if={@track.sandbox_layout != :dedicated} class="hint">
            Private tracks need their own machine. This track shares the project machine.
          </p>
        </form>
        <p :if={@scope == :track && @track.visibility == :project} class="hint">
          Project members work here with their project role.
        </p>
        <ul class="people-list" aria-label="Members">
          <li :for={person <- @people} class="people-row">
            <div class="people-identity">
              <span>@{person.login}</span>
              <small :if={badge(person, @scope)}>{badge(person, @scope)}</small>
            </div>
            <%= if editable?(person, @scope, @admin?, @current_user) do %>
              <button
                type="button"
                id={"#{@id}-role-#{person.login}"}
                class="ghost role-trigger"
                popovertarget={menu_id(@id, person.login)}
                aria-haspopup="menu"
                aria-label={"Role for @#{person.login}: #{role_label(person.role)}"}
                style={"anchor-name: --#{menu_id(@id, person.login)}"}
              >
                {role_label(person.role)}<.icon name="chevron" size={10} open={true} />
              </button>
              <div
                id={menu_id(@id, person.login)}
                class="role-menu"
                popover
                role="menu"
                aria-label={"Role for @#{person.login}"}
                style={"position-anchor: --#{menu_id(@id, person.login)}"}
              >
                <button
                  :for={{value, label, hint} <- roles()}
                  type="button"
                  class="account-item role-option"
                  role="menuitemradio"
                  aria-checked={to_string(Atom.to_string(person.role || :write) == value)}
                  popovertarget={menu_id(@id, person.login)}
                  popovertargetaction="hide"
                  phx-click="set-role"
                  phx-value-login={person.login}
                  phx-value-role={value}
                  phx-target={@myself}
                >
                  <span class="role-option-text">
                    <span>{label}</span><small>{hint}</small>
                  </span>
                  <span class="spacer"></span>
                  <span
                    :if={Atom.to_string(person.role || :write) == value}
                    class="check"
                    aria-hidden="true"
                  >✓</span>
                </button>
                <hr />
                <button
                  type="button"
                  class="account-item role-option danger"
                  role="menuitem"
                  popovertarget={menu_id(@id, person.login)}
                  popovertargetaction="hide"
                  phx-click="remove-person"
                  phx-value-login={person.login}
                  phx-target={@myself}
                >
                  Remove access
                </button>
              </div>
            <% else %>
              <span :if={person.role} class="role-label dim">{role_label(person.role)}</span>
              <button
                :if={removable?(person, @scope, @admin?, @current_user)}
                class="ghost"
                phx-click="remove-person"
                phx-value-login={person.login}
                phx-target={@myself}
              >
                {if person.login == @current_user.login,
                  do: leave_label(@scope),
                  else: "Remove access"}
              </button>
            <% end %>
          </li>
        </ul>
        <p :if={@workspace_project?} id={"#{@id}-workspace-hint"} class="hint workspace-hint">
          This project is shared with members of its workspace.
          <span :if={@workspace_link?}>
            People join it from <.link navigate={"/w/#{@project.workspace_id}"}>the workspace's members page</.link>;
            use Share on a track to add them to it.
          </span>
          <span :if={!@workspace_link?}>
            Ask the project's owner to invite people to the workspace.
          </span>
        </p>
        <form
          :if={@admin? && !@workspace_project?}
          id={"#{@id}-invite-form"}
          phx-change="type-login"
          phx-submit="invite-person"
          phx-target={@myself}
        >
          <.input
            name="login"
            id={"#{@id}-invite-login"}
            label="GitHub username"
            value={@login}
            required
          />
          <.loading_status :if={@inviting?}>Sending invitation…</.loading_status>
          <button class="primary" phx-disable-with="Inviting…" disabled={@inviting?}>Invite</button>
        </form>
        <.invite_link
          :if={!@workspace_project?}
          owner={@admin?}
          invite={@invite}
          target={@myself}
        />
        <div
          :if={@url}
          id={"#{@id}-copy-link"}
          class="share-link copy-link"
          phx-hook="CopyCode"
          data-copy-failed="Copy failed. Select the link and copy it."
        >
          <code>{@url}</code>
          <button type="button" class="ghost">Copy link</button>
          <span role="status" aria-live="polite"></span>
        </div>
        <p :if={@url} class="hint">
          Opens this {@scope} for people who already have access. It does not invite anyone.
        </p>
      </.dialog>
    </div>
    """
  end
end
