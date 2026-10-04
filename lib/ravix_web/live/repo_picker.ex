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
        <div class="repo-picker-search">
          <.icon name="search" size={14} />
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
        </div>
      </form>
      <%!-- The chip shows the selection; this line announces it. --%>
      <p id="repo-picker-selected" class="sr-only" aria-live="polite">
        Selected: <strong :if={!@scratch?}>{@selected.repo}</strong>
        <strong :if={@scratch?}>
          No repository (scratch) · {Ravix.Projects.View.label(@selected, @selected.workspace_id)}
        </strong>
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
            <.icon name="folder" size={14} />
            <span class="truncate">{entry.repo}</span>
            <.icon
              :if={entry.project.id == @selected.id}
              name="check"
              size={14}
              class="repo-picker-check"
            />
          </button>
        </li>
        <li :if={@matches == []} class="hint">No repository here matches.</li>
        <li :if={@picker.can_add} class="repo-picker-utility">
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
        <.repositories
          id="repo-picker-add"
          label="Repositories to add"
          repos={@addable}
          pick="picker-add"
          busy={not is_nil(@picker.adding)}
          adding={@picker.adding}
          empty="Every repository this workspace's GitHub connections reach is already here."
        />
        <button
          type="button"
          id="repo-picker-back"
          class="repo-option ghost repo-picker-back"
          phx-click="picker-add-back"
        >
          <.icon name="chevron" size={13} /> Back to the list
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
        <.icon name="machine" size={14} />
        <span class="truncate">No repository (scratch)</span>
        <.icon :if={@scratch?} name="check" size={14} class="repo-picker-check" />
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :repos, :list, required: true, doc: "`%{repo: \"owner/repo\", private: boolean}` maps"
  attr :pick, :string, required: true, doc: "the event a pick sends, with `repo`"
  attr :target, :any, default: nil
  attr :selected, :string, default: nil
  attr :busy, :boolean, default: false
  attr :adding, :string, default: nil
  attr :empty, :string, required: true

  @doc """
  A list of repositories to pick one of, by name: the picker's "Add a
  repository…" list, and the Danger zone's Change repository (RAV-76), so
  the two look and behave alike. Inside a `data-jump-scope`, the arrow keys
  move through it as they do through the picker's.
  """
  def repositories(assigns) do
    ~H"""
    <ul id={@id} class="repo-picker-list" aria-label={@label}>
      <li :for={repo <- @repos}>
        <button
          type="button"
          class={["repo-option", @selected == repo.repo && "on"]}
          data-jump-result
          data-repo={repo.repo}
          aria-pressed={if @selected, do: to_string(@selected == repo.repo)}
          phx-click={@pick}
          phx-value-repo={repo.repo}
          phx-target={@target}
          disabled={@busy}
        >
          <.icon name="folder" size={14} />
          <span class="truncate">{repo.repo}</span>
          <small :if={repo.private}>Private</small>
          <small :if={@adding == repo.repo}>Adding…</small>
          <.icon :if={@selected == repo.repo} name="check" size={14} class="repo-picker-check" />
        </button>
      </li>
      <li :if={@repos == []} class="hint">{@empty}</li>
    </ul>
    """
  end
end
