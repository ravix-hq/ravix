defmodule RavixWeb.Live.WorkspaceGitHub do
  @moduledoc """
  The GitHub section of a workspace's page (ADR 0009, phase 4b): its
  connections with their standing, "Connect GitHub" for owners and admins,
  and the repository catalog with each repository's project.

  Drawn from `Ravix.Workspaces.Repositories.catalog/2`'s cached answer;
  it never asks GitHub. Its events (`refresh-catalog`, `add-repo`,
  `add-installation`) are the host page's, `RavixWeb.WorkspacePeopleLive`.

  RAV-69: an owner also sees the GitHub accounts they can reach themselves
  that the workspace does not use yet (`Ravix.Workspaces.Connect.available/2`,
  read in the background by `load_available/1`), each with a one-click
  "Add to workspace". With nothing connected that list is the empty state,
  so an owner is never sent to install the App again for an account that
  already has it.
  """
  import Phoenix.LiveView, only: [connected?: 1, start_async: 3, put_flash: 3]

  alias Ravix.Workspaces.Connect
  use RavixWeb, :html

  alias Ravix.Accounts.Access
  alias Ravix.Workspaces.Installation

  @connect_errors %{
    "stale_connect" =>
      "That GitHub connection link had expired or was already used. Press Connect GitHub again.",
    "no_installation" => "GitHub did not return an installation of the Ravix App to connect.",
    "no_authorization" => "GitHub did not confirm who installed the App. Connect GitHub again.",
    "not_your_installation" =>
      "That GitHub installation is not one you can see, so it cannot be connected here.",
    "owner_only" => "Your role in that workspace can no longer connect GitHub.",
    "not_found" => "You can no longer connect GitHub to that workspace."
  }

  @doc "The sentence for a connect round trip that did not finish."
  @spec connect_error(String.t()) :: String.t()
  def connect_error(code),
    do: Map.get(@connect_errors, code, "GitHub could not be connected. Try again.")

  @doc "The sentence for a refresh that left something out."
  @spec refresh_problem([{integer(), term()}], [String.t()]) :: String.t()
  def refresh_problem(errors, collisions) do
    [
      errors != [] &&
        "GitHub did not answer for #{length(errors)} connection(s); their repositories are as last read.",
      collisions != [] &&
        "Renamed on GitHub to a name another project here already has: " <>
          Enum.join(collisions, ", ") <> "."
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  # ── the owner's own accounts (RAV-69) ─────────────────────────────────

  @doc """
  Read, in the background, the accounts the viewer could add: owners only,
  and only once connected, since it asks GitHub. Assigns `available: nil`
  until it answers. The host page passes `:available` results to
  `available_result/2`.
  """
  @spec load_available(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def load_available(socket, workspace_id) do
    user = socket.assigns.current_user

    if connected?(socket) and Access.can?(socket.assigns.role, :add_installations),
      do: start_async(socket, :available, fn -> Connect.available(user, workspace_id) end),
      else: assign(socket, available: nil)
  end

  @doc "Assign what `load_available/2` read. A failure offers nothing, rather than a wrong list."
  @spec available_result(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def available_result(socket, {:ok, {:ok, list}}), do: assign(socket, available: list)
  def available_result(socket, _failed), do: assign(socket, available: [])

  @doc "Start adding one of the viewer's installations; `:add_installation` answers."
  @spec add_installation(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def add_installation(%{assigns: %{attaching: attaching}} = socket, _workspace_id, _id)
      when not is_nil(attaching),
      do: socket

  def add_installation(socket, workspace_id, id) do
    user = socket.assigns.current_user

    socket
    |> assign(attaching: id)
    |> start_async(:add_installation, fn -> Connect.add(user, workspace_id, id) end)
  end

  @doc "Settle an `:add_installation` result: a notice either way."
  @spec installation_added(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def installation_added(socket, {:ok, {:ok, installation}}) do
    socket
    |> assign(attaching: nil)
    |> put_flash(
      :info,
      "Added @#{installation.account_login || installation.installation_id} to this workspace."
    )
  end

  def installation_added(socket, {:ok, {:error, reason}}) do
    socket
    |> assign(attaching: nil)
    |> put_flash(:error, RavixWeb.Error.from(reason, noun: "GitHub account").message)
  end

  def installation_added(socket, {:exit, _reason}) do
    socket
    |> assign(attaching: nil)
    |> put_flash(:error, "The GitHub account could not be added. Try again.")
  end

  attr :workspace, :map, required: true
  attr :role, :atom, required: true
  attr :catalog, :map, default: nil
  attr :refreshing, :boolean, default: false
  attr :adding, :string, default: nil
  attr :available, :list, default: nil
  attr :attaching, :string, default: nil

  @doc "The section."
  def section(assigns) do
    assigns =
      assign(assigns,
        connect?: Access.can?(assigns.role, :connect_repos),
        admit?: Access.can?(assigns.role, :create_project),
        offered: assigns.available || [],
        empty?: assigns.catalog != nil and assigns.catalog.installations == []
      )

    ~H"""
    <section id="workspace-github" aria-labelledby="github-heading">
      <h2 id="github-heading">GitHub</h2>
      <div class="workspace-github-actions">
        <a
          :if={@connect?}
          id="connect-github"
          class={if @empty? and @offered == [], do: "button primary", else: "button ghost"}
          href={"/w/#{@workspace.id}/github/connect"}
        >
          <.icon name="github" size={14} />Connect GitHub
        </a>
        <button
          :if={@catalog && @catalog.installations != []}
          type="button"
          id="refresh-catalog"
          class="ghost"
          phx-click="refresh-catalog"
          disabled={@refreshing}
        >
          {if @refreshing, do: "Refreshing…", else: "Refresh"}
        </button>
      </div>
      <p :if={@empty?} class="hint" id="github-empty">
        No GitHub account is connected yet.
        <span :if={@offered != []}>Add one of yours to use its repositories here.</span>
        <span :if={@connect? and @offered == []}>
          Connect GitHub to add this workspace's repositories.
        </span>
      </p>
      <ul
        :if={@catalog && @catalog.installations != []}
        id="workspace-installations"
        class="workspace-people"
      >
        <li
          :for={installation <- @catalog.installations}
          id={"installation-#{installation.id}"}
          data-account={installation.account_login}
          data-status={Installation.status(installation)}
        >
          <.icon name="github" size={14} />
          <span class="truncate">@{installation.account_login || installation.installation_id}</span>
          <span class="spacer"></span>
          <small :if={Installation.status(installation) == :active}>Connected</small>
          <small :if={Installation.status(installation) != :active} role="note">
            {installation.status_reason || "Not connected"}
          </small>
        </li>
      </ul>

      <h3 :if={@offered != [] and not @empty?} id="available-heading">
        Your other GitHub accounts
      </h3>
      <ul
        :if={@offered != []}
        id="available-installations"
        class="workspace-people"
        aria-label="Your GitHub accounts not in this workspace"
      >
        <li
          :for={installation <- @offered}
          id={"available-#{installation.id}"}
          data-account={installation.account}
        >
          <.icon name="github" size={14} />
          <span class="truncate">@{installation.account}</span>
          <small :if={installation.personal}>Personal account</small>
          <span class="spacer"></span>
          <button
            type="button"
            class={if @empty?, do: "primary", else: "ghost"}
            phx-click="add-installation"
            phx-value-installation={installation.id}
            disabled={not is_nil(@attaching)}
            aria-label={"Add @#{installation.account} to #{@workspace.name}"}
          >
            {if @attaching == to_string(installation.id),
              do: "Adding…",
              else: "Add to workspace"}
          </button>
        </li>
      </ul>
      <p :if={@offered != [] and @workspace.kind == :team} class="hint">
        Every member of {@workspace.name} can then work in its repositories.
      </p>

      <h3 :if={@catalog && @catalog.repos != []} id="catalog-heading">Repositories</h3>
      <ul
        :if={@catalog && @catalog.repos != []}
        id="workspace-catalog"
        class="workspace-people"
        aria-labelledby="catalog-heading"
      >
        <li
          :for={%{repo: repo, project: project} <- @catalog.repos}
          id={"repo-#{repo.id}"}
          data-repo={repo.full_name}
        >
          <span class="truncate">{repo.full_name}</span>
          <small :if={repo.private}>Private</small>
          <span class="spacer"></span>
          <.link :if={project} navigate={"/p/#{project.id}"} class="ghost">Open project</.link>
          <button
            :if={is_nil(project) and @admit?}
            type="button"
            class="ghost"
            phx-click="add-repo"
            phx-value-repo={repo.full_name}
            disabled={not is_nil(@adding)}
          >
            {if @adding == repo.full_name, do: "Adding…", else: "Add"}
          </button>
          <small :if={is_nil(project) and not @admit?}>Not added yet</small>
        </li>
      </ul>
    </section>
    """
  end
end
