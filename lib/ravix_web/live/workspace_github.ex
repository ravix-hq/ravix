defmodule RavixWeb.Live.WorkspaceGitHub do
  @moduledoc """
  The GitHub section of a workspace's page (ADR 0009, phase 4b): its
  connections with their standing, "Connect GitHub" for owners and admins,
  and the repository catalog with each repository's project.

  Drawn from `Ravix.Workspaces.Repositories.catalog/2`'s cached answer;
  it never asks GitHub. Its events (`refresh-catalog`, `add-repo`) are the
  host page's, `RavixWeb.WorkspacePeopleLive`.
  """
  use RavixWeb, :html

  alias Ravix.Accounts.Access
  alias Ravix.Workspaces.Installation

  @connect_errors %{
    "stale_connect" =>
      "That GitHub connection link had expired or was already used. Press Connect GitHub again.",
    "no_installation" => "GitHub did not return an installation of the Ravix App to connect.",
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

  attr :workspace, :map, required: true
  attr :role, :atom, required: true
  attr :catalog, :map, default: nil
  attr :refreshing, :boolean, default: false
  attr :adding, :string, default: nil

  @doc "The section."
  def section(assigns) do
    assigns =
      assign(assigns,
        connect?: Access.can?(assigns.role, :connect_repos),
        admit?: Access.can?(assigns.role, :create_project)
      )

    ~H"""
    <section id="workspace-github" aria-labelledby="github-heading">
      <h2 id="github-heading">GitHub</h2>
      <div class="workspace-github-actions">
        <a
          :if={@connect?}
          id="connect-github"
          class="button primary"
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
      <p :if={@catalog && @catalog.installations == []} class="hint">
        No GitHub account is connected yet.
        <span :if={@connect?}>Connect GitHub to add this workspace's repositories.</span>
      </p>
      <ul
        :if={@catalog && @catalog.installations != []}
        id="workspace-installations"
        class="workspace-people"
      >
        <li
          :for={installation <- @catalog.installations}
          id={"installation-#{installation.installation_id}"}
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

      <h3 :if={@catalog && @catalog.repos != []} id="catalog-heading">Repositories</h3>
      <ul
        :if={@catalog && @catalog.repos != []}
        id="workspace-catalog"
        class="workspace-people"
        aria-labelledby="catalog-heading"
      >
        <li
          :for={%{repo: repo, project: project} <- @catalog.repos}
          id={"repo-#{repo.github_repo_id}"}
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
