defmodule RavixWeb.Live.WorkspaceSwitcher do
  @moduledoc """
  The workspace switcher at the top of the sidebar (ADR 0009, phase 4a).

  Lists the viewer's personal workspace, then their team workspaces, and
  "New workspace…", which opens `new_workspace_dialog/1`. Picking one makes
  it the viewer's *current* workspace
  (`Ravix.Accounts.put_current_workspace/2`), which is what the sidebar,
  quick-jump, badges, the Inbox and New track then show: an event, not a
  navigation. The gear beside the trigger, and "Workspace settings" first
  in the menu, open the current workspace's settings
  (`RavixWeb.Live.WorkspaceSettings`). Drawn only while
  `RAVIX_WORKSPACE_ACCESS` is on: with it off, `list/1` answers nothing and
  the component renders nothing.

  A host page assigns `list/1`'s answer and the current workspace's id,
  renders `switcher/1`, opens the dialog on a `"dialog"` event named
  `"new-workspace"`, routes the dialog form's `"workspace-create"` event to
  `create/2`, and routes `"workspace-select"` to `select/2`, then shows
  whatever the new choice means for it.
  """
  use RavixWeb, :html

  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Ravix.Accounts
  alias Ravix.Accounts.User
  alias Ravix.Workspaces
  alias RavixWeb.Live.Settings

  @doc "The viewer's workspaces for the switcher, personal first; empty while switched off."
  @spec list(User.t() | nil) :: [%{workspace: Ravix.Workspaces.Workspace.t(), role: atom()}]
  def list(%User{} = user) do
    if Workspaces.enabled?(),
      do: Enum.sort_by(Workspaces.list(user), &(&1.workspace.kind != :personal)),
      else: []
  end

  def list(_user), do: []

  @doc """
  Create a team workspace from the New workspace dialog, make it current,
  and go to its members to invite people.
  """
  @spec create(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def create(socket, name) do
    user = socket.assigns.current_user

    case Workspaces.create(user, name) do
      {:ok, workspace} ->
        _ = Accounts.put_current_workspace(user, workspace.id)

        push_patch(socket,
          to: Settings.section_path(:workspace, workspace.id, "members")
        )

      {:error, reason} ->
        put_flash(socket, :error, RavixWeb.Error.from(reason, noun: "workspace").message)
    end
  end

  @doc """
  Make the picked workspace current. The page's `current_user` carries the
  choice from then on; a workspace the viewer is not in is refused with a
  flash and changes nothing.
  """
  @spec select(Phoenix.LiveView.Socket.t(), term()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def select(socket, workspace_id) do
    case Accounts.put_current_workspace(socket.assigns.current_user, workspace_id) do
      {:ok, user} ->
        {:ok, assign(socket, current_user: user)}

      {:error, reason} ->
        {:error,
         put_flash(socket, :error, RavixWeb.Error.from(reason, noun: "workspace").message)}
    end
  end

  attr :workspaces, :list, required: true
  attr :current_id, :string, default: nil

  @doc """
  The switcher: a trigger naming the current workspace, and its menu. With
  no current workspace in hand yet -- a URL about to move the page into
  another one -- a skeleton, never a guess at which it will be (RAV-67).
  """
  def switcher(assigns) do
    current = Enum.find(assigns.workspaces, &(&1.workspace.id == assigns.current_id))
    assigns = assign(assigns, current: current && current.workspace)

    ~H"""
    <div
      :if={@workspaces != [] && is_nil(@current)}
      id="workspace-switcher-skeleton"
      class="workspace-switcher"
      role="status"
    >
      <span class="skeleton workspace-trigger-skeleton" aria-hidden="true"></span>
      <span class="sr-only">Loading workspace…</span>
    </div>
    <div :if={@current} id="workspace-switcher" class="workspace-switcher">
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
      <.link
        id="workspace-settings-gear"
        patch={settings_path(@current)}
        class="ghost workspace-gear"
        aria-label="Workspace settings"
        data-tip="Workspace settings"
      >
        <.icon name="settings" size={14} />
      </.link>
      <div id="workspace-menu" class="workspace-menu" popover>
        <button
          type="button"
          id="workspace-settings"
          class="account-item"
          popovertarget="workspace-menu"
          popovertargetaction="hide"
          phx-click={JS.patch(settings_path(@current))}
        >
          <.icon name="settings" size={14} />Workspace settings
        </button>
        <hr />
        <div role="group" aria-label="Workspaces">
          <button
            :for={%{workspace: workspace} <- @workspaces}
            type="button"
            id={"workspace-select-#{workspace.id}"}
            class="account-item"
            popovertarget="workspace-menu"
            popovertargetaction="hide"
            phx-click="workspace-select"
            phx-value-workspace={workspace.id}
            aria-current={if workspace.id == @current.id, do: "true"}
            data-leaves-page
          >
            <span class="workspace-mark" aria-hidden="true">{initial(workspace.name)}</span>
            <span class="truncate">{workspace.name}</span>
            <span class="spacer"></span>
            <small :if={workspace.kind == :personal}>Personal</small>
          </button>
        </div>
        <hr />
        <button
          type="button"
          id="new-workspace"
          class="account-item"
          popovertarget="workspace-menu"
          popovertargetaction="hide"
          phx-click={
            JS.push_focus(to: "#workspace-switcher-trigger")
            |> JS.push("dialog", value: %{name: "new-workspace"})
          }
        >
          <.icon name="plus" size={14} />New workspace…
        </button>
      </div>
    </div>
    """
  end

  attr :on_close, :any, required: true, doc: "how the dialog closes, as `dialog/1` takes it"

  @doc """
  New workspace: one name and Create. The host renders it while its dialog
  is `:new_workspace`; creating goes to the new workspace's members.
  """
  def new_workspace_dialog(assigns) do
    ~H"""
    <.dialog id="new-workspace-dialog" title="New workspace" on_close={@on_close}>
      <p class="lede">A team workspace, with you as its owner. You can invite people next.</p>
      <form id="new-workspace-form" class="new-workspace" phx-submit="workspace-create">
        <label for="new-workspace-name">Name</label>
        <input
          id="new-workspace-name"
          name="name"
          type="text"
          required
          maxlength="60"
          autocomplete="off"
          placeholder="Team name"
        />
        <button type="submit" class="primary" phx-disable-with="Creating…">Create workspace</button>
      </form>
    </.dialog>
    """
  end

  defp settings_path(workspace),
    do: Settings.section_path(:workspace, workspace.id, "members")

  defp initial(name),
    do: name |> String.trim() |> String.first() |> Kernel.||("?") |> String.upcase()
end
