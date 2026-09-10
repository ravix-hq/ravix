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
  a project member reaches every track on the machine, so its dialog
  explains that and its "leave" is worded for a machine rather than a
  branch.
  """
  use RavixWeb, :live_component

  alias Ravix.People

  @doc "The two units of sharing, and everything that differs between them."
  @spec scopes() :: [:track | :project]
  def scopes, do: [:track, :project]

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     if socket.assigns[:people] do
       socket
     else
       assign(socket, invite: nil) |> load()
     end}
  end

  @impl true
  def handle_event("invite-person", %{"login" => login}, socket) do
    %{scope: scope, subject_id: id, current_user: user} = socket.assigns

    {:noreply,
     result(socket, add(scope, user, id, login), fn s, people ->
       assign(s, people: people)
     end)}
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

  def handle_event("invite-link", %{"action" => action}, socket) do
    %{scope: scope, subject_id: id, current_user: user} = socket.assigns
    minting? = action == "create"

    response = if minting?, do: mint(scope, user, id), else: drop(scope, user, id)

    {:noreply,
     result(socket, response, fn s, value ->
       assign(s, invite: if(minting?, do: value, else: nil))
     end)}
  end

  defp load(socket) do
    %{scope: scope, subject_id: id, current_user: user} = socket.assigns
    result(socket, list(scope, user, id), &assign(&1, people: &2))
  end

  defp list(:track, user, id), do: People.list(user, id)
  defp list(:project, user, id), do: People.list_project(user, id)

  defp add(:track, user, id, login), do: People.add(user, id, login)
  defp add(:project, user, id, login), do: People.add_project(user, id, login)

  defp remove(:track, user, id, login), do: People.remove(user, id, login)
  defp remove(:project, user, id, login), do: People.remove_project(user, id, login)

  defp mint(:track, user, id), do: People.mint_link(user, id)
  defp mint(:project, user, id), do: People.mint_project_link(user, id)

  defp drop(:track, user, id), do: People.drop_link(user, id)
  defp drop(:project, user, id), do: People.drop_project_link(user, id)

  defp title(:track), do: "Track people"
  defp title(:project), do: "Project people"

  defp leave_label(:track), do: "Leave"
  defp leave_label(:project), do: "Leave project"

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.dialog id={"#{@id}-dialog"} title={title(@scope)} on_close="dismiss">
        <p :if={@scope == :project}>
          Project members can open tracks and work in every track on this machine.
        </p>
        <div :for={person <- @people} class="workspace-track">
          <span>@{person.login}</span>
          <button
            :if={@owner || person.login == @current_user.login}
            class="ghost"
            phx-click="remove-person"
            phx-value-login={person.login}
            phx-target={@myself}
          >
            {if person.login == @current_user.login,
              do: leave_label(@scope),
              else: "Remove"}
          </button>
        </div>
        <form :if={@owner} id={"#{@id}-invite-form"} phx-submit="invite-person" phx-target={@myself}>
          <.input name="login" id={"#{@id}-invite-login"} label="GitHub username" value="" required />
          <button class="primary">Invite</button>
        </form>
        <.invite_link owner={@owner} invite={@invite} target={@myself} />
      </.dialog>
    </div>
    """
  end
end
