defmodule RavixWeb.Live.ShareDialog do
  @moduledoc """
  The track header's Share dialog, for a track shared through its workspace
  (ADR 0009 phase 5, RAV-20). It replaces `RavixWeb.Live.PeopleDialog` on a
  workspace project while `RAVIX_WORKSPACE_ACCESS` is on; a legacy project,
  and every project while the switch is off, keeps that dialog, its
  invitations and its links.

  Only whoever manages the track's sharing opens it -- its creator, or the
  project's owner on a project-visible track, as #299 had it -- and within
  it each of three parts is drawn only when `Ravix.People.sharing/2` says
  the caller may use it:

    * **Visibility** -- "Everyone in <workspace>" or "Only people I add".
      The creator's choice; private needs a dedicated machine (#299).
    * **People** -- on a private track, an @-mention box over the
      workspace's current members (a combobox and listbox, driven by the
      `ShareMention` hook), and the people it is shared with. Adding writes
      a permission row and removing deletes it; the server refuses anybody
      outside the workspace, whatever the browser sends.
    * **Copy link** -- the track's own URL. It admits only people who can
      already see the track.

  The creator's one-time consent note (RAV-17) sits above them on a track
  they pay for, until acknowledged or until their first share.
  """
  use RavixWeb, :live_component

  alias Ravix.People

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

  defp visibility_sentence(%{visibility: :private}),
    do: "Only the creator and the people it is shared with can open this track."

  defp visibility_sentence(%{workspace: workspace}),
    do: "Everyone in #{workspace} can open this track."

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.dialog id={"#{@id}-dialog"} title="Share track" on_close="dismiss">
        <div :if={@sharing} class="share-dialog">
          <div :if={@sharing.consent} id="share-consent" class="share-consent" role="note">
            <p>{@sharing.consent}</p>
            <button type="button" class="ghost" phx-click="consent" phx-target={@myself}>
              I understand
            </button>
          </div>

          <form
            :if={@sharing.set_visibility}
            id="share-visibility-form"
            phx-change="visibility"
            phx-target={@myself}
          >
            <fieldset class="share-visibility">
              <legend>Who can open this track</legend>
              <label>
                <input
                  type="radio"
                  name="visibility"
                  value="project"
                  checked={@sharing.visibility == :project}
                /> Everyone in {@sharing.workspace}
              </label>
              <label :if={@sharing.private_allowed or @sharing.visibility == :private}>
                <input
                  type="radio"
                  name="visibility"
                  value="private"
                  checked={@sharing.visibility == :private}
                /> Only people I add
              </label>
            </fieldset>
            <p :if={!@sharing.private_allowed} class="hint">
              Private tracks need their own machine. This track shares the project machine.
            </p>
          </form>
          <p :if={!@sharing.set_visibility} id="share-visibility">
            {visibility_sentence(@sharing)}
          </p>

          <section :if={@sharing.visibility == :private} aria-labelledby="share-people-title">
            <h3 id="share-people-title">People</h3>
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
            <p :if={@sharing.holders == []} class="dim">Not shared with anyone yet.</p>
            <ul :if={@sharing.holders != []} class="people-list" aria-label="Shared with">
              <li :for={person <- @sharing.holders} class="people-row">
                <div class="people-identity">
                  <span>@{person.login}</span>
                  <small :if={person.name}>{person.name}</small>
                </div>
                <button
                  :if={@sharing.manage_people}
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
          </section>

          <div
            id="share-link"
            class="share-link"
            phx-hook="CopyCode"
            data-copy-failed="Copy failed. Select the link and copy it."
          >
            <code>{@sharing.url}</code>
            <button type="button" class="ghost">Copy link</button>
            <span role="status" aria-live="polite"></span>
          </div>
          <p class="hint">The link opens this track only for people who can already see it.</p>
        </div>
      </.dialog>
    </div>
    """
  end
end
