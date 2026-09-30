defmodule RavixWeb.Live.RepoPicker do
  @moduledoc """
  The New track repository list (RAV-10, ADR 0009 phase 4c), inside
  `WorkspaceLive`'s New track dialog while `RAVIX_WORKSPACE_ACCESS` is on,
  as the repository chip's popover (RAV-60): a pick marks itself
  `data-chip-close`, so choosing closes the popover.

  A type-ahead over the current workspace's repositories, matching
  `owner/repo`, most recently used first, then alphabetical; "Add a
  repository…" as its last entry for owners and admins; and "No repository
  (scratch)" apart from it. Keyboard-first as quick-jump is: the same
  `QuickJump` hook moves through the results with the arrow keys and picks
  the first one on Enter (`data-jump-scope`, `data-jump-query`,
  `data-jump-result`). What it lists is `Ravix.Workspaces.Picker`'s; its
  events are the host page's (`picker-*`).
  """
  use RavixWeb, :html

  alias Ravix.Workspaces.Picker

  attr :picker, Picker, required: true
  attr :selected, :map, required: true
  attr :busy, :boolean, default: false

  @doc "The picker."
  def picker(assigns) do
    assigns =
      assign(assigns,
        matches: Picker.matches(assigns.picker),
        addable: Picker.addable_matches(assigns.picker),
        scratch?: is_nil(assigns.selected.repo)
      )

    ~H"""
    <div id="repo-picker" class="repo-picker" data-jump-scope>
      <form id="repo-picker-form" phx-change="picker-filter" phx-submit="picker-submit">
        <label for="repo-picker-query">
          {if @picker.mode == :add, do: "Add a repository", else: "Repository"}
          <small :if={@picker.workspace}>in {@picker.workspace.name}</small>
        </label>
        <input
          id="repo-picker-query"
          name="q"
          type="search"
          value={@picker.query}
          placeholder="owner/repo"
          autocomplete="off"
          phx-debounce="100"
          data-jump-query
          aria-controls={if @picker.mode == :add, do: "repo-picker-add", else: "repo-picker-list"}
          aria-describedby="repo-picker-selected"
          disabled={@busy}
        />
      </form>
      <%!-- The chip shows the selection; this line announces it. --%>
      <p id="repo-picker-selected" class="sr-only" aria-live="polite">
        Selected: <strong :if={!@scratch?}>{@selected.repo}</strong>
        <strong :if={@scratch?}>No repository (scratch) · {@selected.display_name}</strong>
      </p>

      <ul
        :if={@picker.mode == :repos}
        id="repo-picker-list"
        class="repo-picker-list"
        aria-label="Repositories"
      >
        <li :for={entry <- @matches}>
          <button
            type="button"
            id={"repo-option-#{entry.project.id}"}
            class={["repo-option", entry.project.id == @selected.id && "on"]}
            data-jump-result
            data-chip-close
            aria-pressed={to_string(entry.project.id == @selected.id)}
            phx-click="picker-pick"
            phx-value-project={entry.project.id}
            disabled={@busy}
          >
            <span class="truncate">{entry.repo}</span>
          </button>
        </li>
        <li :if={@matches == []} class="hint">No repository here matches.</li>
        <li :if={@picker.can_add}>
          <button
            type="button"
            id="repo-option-add"
            class="repo-option ghost"
            data-jump-result
            phx-click="picker-add-open"
            disabled={@busy}
          >
            <.icon name="plus" size={13} />Add a repository…
          </button>
        </li>
      </ul>

      <div :if={@picker.mode == :add}>
        <ul id="repo-picker-add" class="repo-picker-list" aria-label="Repositories to add">
          <li :for={repo <- @addable}>
            <button
              type="button"
              class="repo-option"
              data-jump-result
              data-repo={repo.repo}
              phx-click="picker-add"
              phx-value-repo={repo.repo}
              disabled={not is_nil(@picker.adding)}
            >
              <span class="truncate">{repo.repo}</span>
              <small :if={repo.private}>Private</small>
              <small :if={@picker.adding == repo.repo}>Adding…</small>
            </button>
          </li>
          <li :if={@addable == []} class="hint">
            Every repository this workspace's GitHub connections reach is already here.
          </li>
        </ul>
        <button type="button" id="repo-picker-back" class="ghost" phx-click="picker-add-back">
          Back to the list
        </button>
      </div>

      <button
        type="button"
        id="repo-option-scratch"
        class={["repo-option repo-scratch", @scratch? && "on"]}
        aria-pressed={to_string(@scratch?)}
        data-chip-close
        phx-click="picker-scratch"
        disabled={@busy}
      >
        No repository (scratch)
      </button>
    </div>
    """
  end
end
