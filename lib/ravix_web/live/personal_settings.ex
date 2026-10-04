defmodule RavixWeb.Live.PersonalSettings do
  @moduledoc """
  The signed-in person's own settings, `/settings/:section`, in the
  settings frame (`RavixWeb.Live.Settings`, RAV-72). The footer's You menu
  links to each section (RAV-77):

    * **Profile**: who they are signed in as, read-only. The name, login
      and picture are GitHub's, so the page says where to change them rather
      than offering a form that GitHub's next sign-in would undo. Sign out
      everywhere ends every session of the person on the page
      (`Ravix.Accounts.end_all_sessions/1`), never one a browser names.
    * **Agents**: `RavixWeb.Live.AgentPanel` in its compact layout, the
      same one the walkthrough draws. Its clock and its `:agent_connected`
      messages go through `RavixWeb.WorkspaceLive`, like the account
      dialog's.
    * **Notifications** and **Appearance**: desktop notifications and the
      theme, the same switches as the You menu's quick toggles. Both are
      this browser's preferences, kept in localStorage by the
      `NotifyToggle` and `Theme` hooks, so neither has a Save or reaches
      the server. Notifications also says what reaches the Inbox; that is
      `RavixWeb.WorkspaceLive`'s rule, and not a choice anybody makes yet.
    * **Connected apps**: the OAuth connections that were
      `/settings/connections`, by client name and date. Disconnecting is
      still a plain form post to `RavixWeb.ToolingOAuthController`, which
      comes back here. Where a connection came from (an address, a user
      agent) is not recorded or shown.

  Its one event is Sign out everywhere; the panel's are the panel's. Each
  asks about the session first (`RavixWeb.Live.Hooks`).

  Beside it the nav lists the current workspace's settings, when there is
  one, so a person moves between the two without the switcher.
  """
  use RavixWeb, :live_component
  alias Ravix.Accounts
  alias Ravix.Tooling.OAuth
  alias RavixWeb.Live.Settings

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    connections =
      if socket.assigns.section == "connected-apps",
        do: OAuth.connections(socket.assigns.current_user),
        else: []

    {:ok, assign(socket, connections: connections)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="personal-settings" class="settings-host settings-shell">
      <Settings.frame
        kind={:personal}
        section={@section}
        crumbs={["You"]}
        nav={[
          Settings.you_group() | if(@workspace, do: [Settings.workspace_group(@workspace)], else: [])
        ]}
      >
        <.profile
          :if={@section == "profile"}
          user={@current_user}
          workspace={@workspace}
          myself={@myself}
        />
        <.agents
          :if={@section == "agents"}
          current_user={@current_user}
          session_hash={@session_hash}
        />
        <.notifications :if={@section == "notifications"} />
        <.appearance :if={@section == "appearance"} />
        <RavixWeb.ToolingOAuthHTML.connections
          :if={@section == "connected-apps"}
          connections={@connections}
          framed
        />
      </Settings.frame>
    </div>
    """
  end

  @impl true
  def handle_event("sign-out-everywhere", _params, socket) do
    {:ok, _count} = Accounts.end_all_sessions(socket.assigns.current_user)
    {:noreply, redirect(socket, to: "/login")}
  end

  attr :user, :map, required: true
  attr :workspace, :map, default: nil, doc: "the current workspace, whose Repositories it links"
  attr :myself, :any, required: true

  defp profile(assigns) do
    ~H"""
    <section id="settings-profile" class="settings-row" aria-labelledby="settings-title">
      <div class="settings-row-copy">
        <div class="profile-identity">
          <img
            :if={@user.avatar_url}
            src={@user.avatar_url}
            alt=""
            class="profile-avatar"
            width="40"
            height="40"
          />
          <span :if={!@user.avatar_url} class="profile-avatar" aria-hidden="true">
            <.icon name="person" size={20} />
          </span>
          <div class="profile-names">
            <strong id="profile-name">{@user.name || @user.login}</strong>
            <span id="profile-login" class="dim">@{@user.login}</span>
          </div>
        </div>
        <p class="hint">
          Your name, login and picture come from GitHub and update when you next sign in.
        </p>
      </div>
      <div class="settings-row-controls">
        <a
          class="link-button"
          href="https://github.com/settings/profile"
          target="_blank"
          rel="noopener noreferrer"
        >
          Edit on GitHub ↗
        </a>
      </div>
    </section>
    <section class="settings-row" aria-labelledby="profile-github-title">
      <div class="settings-row-copy">
        <h2 id="profile-github-title">Repository access</h2>
        <p class="hint">
          Ravix works only in the repositories you let its GitHub App read.
        </p>
        <p :if={@workspace} class="hint">
          <.link
            id="profile-workspace-repositories"
            patch={Settings.section_path(:workspace, @workspace.id, "repositories")}
          >
            See the repositories {@workspace.name} uses →
          </.link>
        </p>
      </div>
      <div class="settings-row-controls">
        <a id="profile-repository-access" class="link-button" href="/api/auth/install">
          Manage repositories ↗
        </a>
      </div>
    </section>
    <section class="settings-row" aria-labelledby="profile-session-title">
      <div class="settings-row-copy">
        <h2 id="profile-session-title">Sessions</h2>
        <p class="hint">
          Sign out of this browser or all devices. Your projects and tracks keep running.
        </p>
      </div>
      <div class="settings-row-controls">
        <.link id="profile-sign-out" href="/auth/signout" method="post" class="link-button">
          Sign out
        </.link>
        <button
          type="button"
          id="profile-sign-out-everywhere"
          class="danger"
          phx-click="sign-out-everywhere"
          phx-target={@myself}
          data-confirm="Sign out of Ravix in every browser and on every device, including this one?"
        >
          Sign out everywhere
        </button>
      </div>
    </section>
    """
  end

  attr :current_user, :map, required: true
  attr :session_hash, :string, required: true

  defp agents(assigns) do
    ~H"""
    <section id="settings-agents" aria-labelledby="settings-title">
      <p class="lede">
        Connect your agents and choose a default for new projects. The project owner’s subscription or API key pays for everyone’s turns.
      </p>
      <.live_component
        module={RavixWeb.Live.AgentPanel}
        id="settings-agent-panel"
        compact={true}
        current_user={@current_user}
        session_hash={@session_hash}
      />
    </section>
    """
  end

  defp notifications(assigns) do
    ~H"""
    <section id="settings-notifications" class="settings-row" aria-labelledby="notify-setting-label">
      <div class="settings-row-copy">
        <h2 id="notify-setting-label">Desktop notifications</h2>
        <p id="notify-setting-hint" class="hint">
          Get notified when a track needs you while this tab is in the background.
          Enable this in each browser you use.
        </p>
      </div>
      <div id="notify-setting" phx-hook="NotifyToggle" class="notify settings-row-controls">
        <button
          type="button"
          class="settings-row-toggle"
          data-notify-toggle
          aria-pressed="false"
          aria-labelledby="notify-setting-label notify-setting-state"
          aria-describedby="notify-setting-hint"
        >
          <span class="sr-only">Desktop notifications</span>
          <span id="notify-setting-state" data-notify-state>Off</span>
          <span class="settings-row-switch" data-notify-dot aria-hidden="true"></span>
        </button>
      </div>
    </section>
    <section
      id="settings-inbox"
      class="personal-section settings-note"
      aria-labelledby="settings-inbox-title"
    >
      <h2 id="settings-inbox-title">What reaches your Inbox</h2>
      <p class="hint">
        A track comes to your <.link patch="/inbox">Inbox</.link>, and to your desktop when notifications are on, when:
      </p>
      <ul class="inbox-rules">
        <li>the agent has replied and you have not read it yet;</li>
        <li>a track or its machine setup failed;</li>
        <li>somebody mentions you in a comment;</li>
        <li>a track you pay for is paused until you reconnect your agent.</li>
      </ul>
      <p class="hint">
        Inside a workspace, the Inbox shows that workspace's tracks and says how many are waiting in your others.
      </p>
    </section>
    """
  end

  defp appearance(assigns) do
    ~H"""
    <section id="settings-appearance" class="settings-row" aria-labelledby="appearance-theme-label">
      <div class="settings-row-copy">
        <h2 id="appearance-theme-label">Color mode</h2>
        <p class="hint">
          Auto follows your device’s light or dark appearance. Saved for this browser.
        </p>
      </div>
      <div class="settings-row-controls">
        <.theme_picker id="appearance-mode" />
      </div>
    </section>
    <details id="appearance-advanced" class="settings-advanced">
      <summary>Advanced / Experimental</summary>
      <section class="settings-row" aria-labelledby="appearance-palette-label">
        <div class="settings-row-copy">
          <h2 id="appearance-palette-label">Custom theme</h2>
          <p class="hint">
            Extra palettes override Auto, Light, and Dark. Hover a palette to preview it.
          </p>
        </div>
        <div class="settings-row-controls">
          <.theme_picker id="appearance-theme" experimental />
        </div>
      </section>
    </details>
    """
  end
end
