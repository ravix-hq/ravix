defmodule RavixWeb.Live.ShareDialog do
  @moduledoc """
  The track header's Share popover, for a track shared through its
  workspace (ADR 0009 phase 5, RAV-20). It replaces `RavixWeb.Live.PeopleDialog`
  on a workspace project while `RAVIX_WORKSPACE_ACCESS` is on; a legacy
  project, and every project while the switch is off, keeps that dialog,
  its invitations and its links.

  Only whoever manages the track's sharing opens it -- its creator, or the
  project's owner on a project-visible track, as #299 had it -- and within
  it each part offers a control only when `Ravix.People.sharing/2` says the
  caller may use it; every event is checked again on the server:

    * **Add people** -- on a private track, an @-mention box over the
      workspace's current members (a combobox and listbox, driven by the
      `ShareMention` hook). Adding writes a permission row; the server
      refuses anybody outside the workspace, whatever the browser sends.
    * **People with access** -- always, whatever the general access:
      everyone who reaches the track, each with their role and where it
      comes from (RAV-75): "Write · from project", "Read · direct". Those
      it is shared with carry Remove for whoever manages the people.
    * **General access** -- one row: "Everyone in <workspace>" with the
      workspace's role, or "Only people I add". The creator's choice;
      private needs a dedicated machine (#299).
    * **Copy link** -- the track's own URL, copied without being printed
      (RAV-84), from the button or its `C` shortcut. It admits only people
      who can already see the track.

  RAV-84 draws it as a popover under the Share button with no scrim: the
  `SharePopover` hook places it, and closes it on a second click of Share.
  Escape and a click outside close it as a dialog closes (RAV-68), and
  focus returns to Share. On a narrow viewport it is the centred dialog
  it used to be.

  The creator's one-time consent note (RAV-17) sits above them on a track
  they pay for, until acknowledged or until their first share.
  """
  use RavixWeb, :live_component

  alias Ravix.People
  alias RavixWeb.Live.PeopleDialog

  @impl true
  def mount(socket), do: {:ok, assign(socket, sharing: nil, q: "", candidates: [])}

  @impl true
  def update(%{reload: true}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, if(socket.assigns.sharing, do: socket, else: load(socket))}
  end

  @impl true
  def handle_event("visibility", %{"visibility" => visibility}, socket) do
    %{current_user: user, track_id: id} = socket.assigns

    {:noreply,
     result(socket, Ravix.Tracks.set_visibility(user, id, visibility), fn s, _value ->
       # `set_visibility/3` tells the hub, which refreshes the header's lock.
       s |> assign(q: "", candidates: []) |> load()
     end)}
  end

  def handle_event("search", %{"q" => q}, socket) do
    %{current_user: user, track_id: id} = socket.assigns

    if String.trim(q) == "" do
      {:noreply, assign(socket, q: q, candidates: [])}
    else
      {:noreply,
       result(socket, People.share_candidates(user, id, q), &assign(&1, q: q, candidates: &2))}
    end
  end

  def handle_event("add", params, socket) do
    %{current_user: user, track_id: id} = socket.assigns
    login = params["login"] || params["q"] || ""

    {:noreply,
     result(socket, People.share_login(user, id, login), fn s, _ ->
       s |> assign(q: "", candidates: []) |> load()
     end)}
  end

  def handle_event("remove", %{"login" => login}, socket) do
    %{current_user: user, track_id: id} = socket.assigns

    {:noreply,
     result(socket, People.unshare_login(user, id, login), fn s, _ ->
       send(self(), {:person_removed, :track, login})
       load(s)
     end)}
  end

  def handle_event("consent", _params, socket) do
    %{current_user: user, track_id: id} = socket.assigns
    {:noreply, result(socket, People.consent_sharing(user, id), fn s, _ -> load(s) end)}
  end

  defp load(socket) do
    %{current_user: user, track_id: id} = socket.assigns
    result(socket, People.sharing(user, id), &assign(&1, sharing: &2))
  end

  @doc """
  Where somebody's role on a track comes from, as a row in the dialog says
  it. On a private track the `:owner` is whoever made it, which may not be
  the project's owner.
  """
  @spec source_label(Ravix.Accounts.Access.track_source(), :project | :private) :: String.t()
  def source_label(:owner, :private), do: "creator"
  def source_label(:owner, _visibility), do: "owner"
  def source_label(:direct, _visibility), do: "direct"
  def source_label(:project, _visibility), do: "from project"
  def source_label(:workspace, _visibility), do: "from workspace"

  defp role_label(level), do: PeopleDialog.role_label(level)

  defp visibility_sentence(%{visibility: :private}),
    do: "Only the creator and the people it is shared with can open this track."

  defp visibility_sentence(%{workspace: workspace}),
    do: "Everyone in #{workspace} can open this track."

  # The general-access row's own sentence, under its scope.
  defp scope_label(:private, _workspace), do: "Only people I add"
  defp scope_label(_visibility, workspace), do: "Everyone in #{workspace}"

  @impl true
  def render(assigns) do
    # As `.dialog/1` closes (RAV-68): `hidden` goes on synchronously, so the
    # next click is not lost to a panel the server has not yet removed, then
    # the page hears `dismiss` and focus goes back to Share.
    close =
      JS.set_attribute({"hidden", ""}, to: "##{assigns.id}-dialog")
      |> JS.push("dismiss")
      |> JS.pop_focus()

    holders = if assigns.sharing, do: MapSet.new(assigns.sharing.holders, & &1.login)
    assigns = assign(assigns, close: close, holder_logins: holders || MapSet.new())

    ~H"""
    <div id={@id}>
      <div
        id={"#{@id}-dialog"}
        class="share-layer"
        phx-hook="SharePopover"
        data-anchor="track-share-button"
        data-close={@close}
      >
        <.focus_wrap
          id={"#{@id}-dialog-dialog"}
          class="share-popover"
          role="dialog"
          aria-modal="true"
          aria-labelledby={"#{@id}-dialog-title"}
          tabindex="-1"
          phx-window-keydown={@close}
          phx-key="escape"
          phx-click-away={@close}
          phx-mounted={JS.focus_first(to: "##{@id}-dialog-dialog")}
        >
          <div class="dialog-head">
            <h2 id={"#{@id}-dialog-title"}>Share track</h2>
            <span class="spacer" />
            <.icon_button icon="x" size={16} label="Close" class="x" phx-click={@close} />
          </div>
          <div :if={@sharing} class="dialog-body share-dialog">
            <div :if={@sharing.consent} id="share-consent" class="share-consent" role="note">
              <p>{@sharing.consent}</p>
              <button type="button" class="ghost" phx-click="consent" phx-target={@myself}>
                I understand
              </button>
            </div>

            <form
              :if={@sharing.manage_people}
              id="share-person-form"
              class="share-mention"
              phx-hook="ShareMention"
              phx-change="search"
              phx-submit="add"
              phx-target={@myself}
              autocomplete="off"
            >
              <label for="share-person">Add workspace members</label>
              <input
                id="share-person"
                name="q"
                type="text"
                value={@q}
                role="combobox"
                aria-autocomplete="list"
                aria-expanded={to_string(@candidates != [])}
                aria-controls="share-person-options"
                aria-describedby="share-person-hint"
                placeholder="@name"
                phx-debounce="150"
              />
              <ul
                id="share-person-options"
                role="listbox"
                aria-label={"Members of #{@sharing.workspace}"}
                hidden={@candidates == []}
              >
                <li
                  :for={person <- @candidates}
                  id={"share-option-#{person.login}"}
                  role="option"
                  aria-selected="false"
                  data-login={person.login}
                  phx-click="add"
                  phx-value-login={person.login}
                  phx-target={@myself}
                >
                  <span>@{person.login}</span>
                  <small :if={person.name} class="dim">{person.name}</small>
                </li>
              </ul>
              <p id="share-person-hint" class="hint">
                Only members of {@sharing.workspace} can be added.
              </p>
            </form>

            <section aria-labelledby="share-access-title">
              <h3 id="share-access-title">People with access</h3>
              <ul id="share-access" class="people-list" aria-labelledby="share-access-title">
                <li
                  :for={{person, level, source} <- @sharing.access}
                  id={"share-access-#{person.login}"}
                  class="people-row"
                >
                  <div class="people-identity">
                    <span>@{person.login}</span>
                    <small :if={person.name}>{person.name}</small>
                  </div>
                  <span class="role-label">{role_label(level)}</span>
                  <span class="people-source">· {source_label(source, @sharing.visibility)}</span>
                  <button
                    :if={@sharing.manage_people and MapSet.member?(@holder_logins, person.login)}
                    type="button"
                    class="ghost"
                    phx-click="remove"
                    phx-value-login={person.login}
                    phx-target={@myself}
                    aria-label={"Remove @#{person.login}"}
                  >
                    Remove
                  </button>
                </li>
              </ul>
              <p :if={@sharing.visibility == :private and @sharing.holders == []} class="dim hint">
                Not shared with anyone yet.
              </p>
            </section>

            <section aria-labelledby="share-general-title" class="share-general">
              <h3 id="share-general-title">General access</h3>
              <form
                :if={@sharing.set_visibility}
                id="share-visibility-form"
                class="share-general-row"
                phx-change="visibility"
                phx-target={@myself}
              >
                <.icon name={if @sharing.visibility == :private, do: "lock", else: "globe"} size={15} />
                <select
                  id="share-visibility-scope"
                  name="visibility"
                  aria-label="General access"
                  aria-describedby="share-visibility"
                >
                  <option value="project" selected={@sharing.visibility == :project}>
                    {scope_label(:project, @sharing.workspace)}
                  </option>
                  <option
                    :if={@sharing.private_allowed or @sharing.visibility == :private}
                    value="private"
                    selected={@sharing.visibility == :private}
                  >
                    {scope_label(:private, @sharing.workspace)}
                  </option>
                </select>
                <span :if={@sharing.general_level} class="role-label">
                  {role_label(@sharing.general_level)}
                </span>
              </form>
              <div :if={!@sharing.set_visibility} class="share-general-row">
                <.icon name={if @sharing.visibility == :private, do: "lock", else: "globe"} size={15} />
                <span class="share-general-scope">
                  {scope_label(@sharing.visibility, @sharing.workspace)}
                </span>
                <span :if={@sharing.general_level} class="role-label">
                  {role_label(@sharing.general_level)}
                </span>
              </div>
              <p id="share-visibility" class="hint">{visibility_sentence(@sharing)}</p>
              <p :if={@sharing.set_visibility and !@sharing.private_allowed} class="hint">
                Private tracks need their own machine. This track shares the project machine.
              </p>
            </section>

            <div
              id="share-link"
              class="share-link"
              phx-hook="CopyCode"
              data-copy={@sharing.url}
              data-copy-failed="Copy failed. Copy the address from the browser instead."
            >
              <button
                type="button"
                class="ghost"
                aria-describedby="share-link-hint"
                aria-keyshortcuts="c"
                title="The link opens this track only for people who can already see it."
              >
                <.icon name="copy" size={14} /><span>Copy link</span>
              </button>
              <kbd aria-hidden="true" title="Shortcut: C">C</kbd>
              <span role="status" aria-live="polite"></span>
              <p id="share-link-hint" class="hint">
                The link opens this track only for people who can already see it.
              </p>
            </div>
          </div>
        </.focus_wrap>
      </div>
    </div>
    """
  end
end
