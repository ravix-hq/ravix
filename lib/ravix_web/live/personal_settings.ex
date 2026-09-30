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
    <div id="personal-settings" class="settings-host">
      <Settings.frame
        kind={:personal}
        section={@section}
        crumbs={["You"]}
        nav={[
          Settings.you_group() | if(@workspace, do: [Settings.workspace_group(@workspace)], else: [])
        ]}
      >
        <.profile :if={@section == "profile"} user={@current_user} myself={@myself} />
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
  attr :myself, :any, required: true

  defp profile(assigns) do
    ~H"""
    <section id="settings-profile" class="personal-section" aria-labelledby="settings-title">
      <div class="profile-identity">
        <img
          :if={@user.avatar_url}
          src={@user.avatar_url}
          alt=""
          class="profile-avatar"
          width="64"
          height="64"
        />
        <span :if={!@user.avatar_url} class="profile-avatar" aria-hidden="true">
          <.icon name="person" size={28} />
        </span>
        <div class="profile-names">
          <strong id="profile-name">{@user.name || @user.login}</strong>
          <span id="profile-login" class="dim">@{@user.login}</span>
        </div>
      </div>
      <p class="hint">
        Your name, login and picture come from GitHub and update when you next sign in.
        <a href="https://github.com/settings/profile" target="_blank" rel="noopener noreferrer">
          Change them on GitHub ↗
        </a>
      </p>
    </section>
    <section class="personal-section" aria-labelledby="profile-github-title">
      <h2 id="profile-github-title">Repository access</h2>
      <p class="hint">
        Ravix works only in the repositories you let its GitHub App read.
      </p>
      <p>
        <a id="profile-repository-access" href="/api/auth/install">
          Change which GitHub repositories Ravix may work in ↗
        </a>
      </p>
    </section>
    <section class="personal-section" aria-labelledby="profile-session-title">
      <h2 id="profile-session-title">Sessions</h2>
      <p class="hint">
        Sign out here, or everywhere you are signed in: every browser and device, this one included. Your projects and tracks carry on.
      </p>
      <div class="workspace-actions">
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
        Connect either or both agents and choose a default for new projects. Each project uses its selected agent, paid for by its owner’s subscription or API key, whoever is working.
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
    <section id="settings-notifications" class="personal-section">
      <div id="notify-setting" phx-hook="NotifyToggle" class="notify">
        <button
          type="button"
          class="theme-trigger"
          data-notify-toggle
          aria-pressed="false"
          aria-describedby="notify-setting-hint"
        >
          <span class="notify-dot" data-notify-dot></span><span class="col"><small>Desktop notifications</small><span
            class="truncate"
            data-notify-state
          >Off</span></span>
        </button>
      </div>
      <p id="notify-setting-hint" class="hint">
        Say so from the desktop when a track needs you and this tab is in the background.
        This is a setting of this browser: turn it on in each browser you use. The same switch is in the You menu.
      </p>
    </section>
    <section
      id="settings-inbox"
      class="personal-section"
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
    <section id="settings-appearance" class="personal-section">
      <.theme_picker id="appearance-theme" />
      <p class="hint">
        The theme is a setting of this browser. Hover a palette to preview it.
      </p>
    </section>
    """
  end
end
