defmodule RavixWeb.Live.WorkspaceSwitcher do
  @moduledoc """
  The workspace switcher at the top of the sidebar (ADR 0009, phase 4a).

  Lists the viewer's personal workspace, then their team workspaces, each a
  link to that workspace's page (`RavixWeb.WorkspacePeopleLive`), and a
  "New workspace" form. Drawn only while `RAVIX_WORKSPACE_ACCESS` is on:
  with it off, `list/1` answers nothing and the component renders nothing.

  Self-contained on purpose. A host page assigns `list/1`'s answer, renders
  `switcher/1`, and routes the form's `"workspace-create"` event to
  `create/2`; nothing else on the page depends on it.
  """
  use RavixWeb, :html

  import Phoenix.LiveView, only: [push_navigate: 2, put_flash: 3]

  alias Ravix.Accounts.User
  alias Ravix.Workspaces

  @doc "The viewer's workspaces for the switcher, personal first; empty while switched off."
  @spec list(User.t() | nil) :: [%{workspace: Ravix.Workspaces.Workspace.t(), role: atom()}]
  def list(%User{} = user) do
    if Workspaces.enabled?(),
      do: Enum.sort_by(Workspaces.list(user), &(&1.workspace.kind != :personal)),
      else: []
  end

  def list(_user), do: []

  @doc "Create a team workspace from the switcher's form and go to it."
  @spec create(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def create(socket, name) do
    case Workspaces.create(socket.assigns.current_user, name) do
      {:ok, workspace} ->
        push_navigate(socket, to: "/w/#{workspace.id}")

      {:error, reason} ->
        put_flash(socket, :error, RavixWeb.Error.from(reason, noun: "workspace").message)
    end
  end

  attr :workspaces, :list, required: true
  attr :current_id, :string, default: nil

  @doc "The switcher: a trigger naming the current workspace, and its menu."
  def switcher(assigns) do
    current =
      Enum.find(assigns.workspaces, &(&1.workspace.id == assigns.current_id)) ||
        List.first(assigns.workspaces)

    assigns = assign(assigns, current: current && current.workspace)

    ~H"""
    <div :if={@workspaces != []} id="workspace-switcher" class="workspace-switcher">
      <button
        type="button"
        id="workspace-switcher-trigger"
        class="ghost workspace-trigger"
        popovertarget="workspace-menu"
        aria-label={"Workspace: #{@current.name}. Switch workspace"}
      >
        <span class="workspace-mark" aria-hidden="true">{initial(@current.name)}</span>
        <span class="truncate">{@current.name}</span>
        <.icon name="chevron" size={12} />
      </button>
      <div id="workspace-menu" class="workspace-menu" popover>
        <nav aria-label="Workspaces">
          <.link
            :for={%{workspace: workspace} <- @workspaces}
            navigate={"/w/#{workspace.id}"}
            class="account-item"
            aria-current={if workspace.id == @current.id, do: "page"}
          >
            <span class="workspace-mark" aria-hidden="true">{initial(workspace.name)}</span>
            <span class="truncate">{workspace.name}</span>
            <span class="spacer"></span>
            <small :if={workspace.kind == :personal}>Personal</small>
          </.link>
        </nav>
        <hr />
        <form id="new-workspace-form" class="new-workspace" phx-submit="workspace-create">
          <label for="new-workspace-name">New workspace</label>
          <input
            id="new-workspace-name"
            name="name"
            type="text"
            required
            maxlength="60"
            autocomplete="off"
            placeholder="Team name"
          />
          <button type="submit" class="primary">Create workspace</button>
        </form>
      </div>
    </div>
    """
  end

  defp initial(name),
    do: name |> String.trim() |> String.first() |> Kernel.||("?") |> String.upcase()
end
