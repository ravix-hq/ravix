defmodule RavixWeb.ToolingOAuthHTML do
  @moduledoc "Explicit consent and revocation for desktop agent connections."
  use RavixWeb, :html

  def consent(assigns) do
    ~H"""
    <div class="landing">
      <header class="landing-nav"><strong>Ravix</strong></header>
      <main class="invite">
        <h1>Connect {@request.client.name} to Ravix</h1>
        <p>
          This client name is supplied by the application. Check the destination before allowing access.
        </p>
        <p>Return to: <code>{@request.redirect_uri}</code></p>
        <p>Resource: <code>{@request.resource}</code></p>
        <p>This connection can act on projects and tracks you can access, including future ones:</p>
        <ul>
          <li :for={scope <- @request.scopes}>{description(scope)}</li>
        </ul>
        <form action="/oauth/authorize" method="post">
          <input type="hidden" name="consent_nonce" value={@nonce} />
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <button class="landing-button landing-primary" type="submit" name="decision" value="allow">Allow access</button>
          <button class="landing-button" type="submit" name="decision" value="deny">Deny</button>
        </form>
        <p>
          You can disconnect this application in <a href="/settings/connections">Connected applications</a>.
        </p>
      </main>
    </div>
    """
  end

  def connections(assigns) do
    ~H"""
    <div id="connections-panel" class="inbox connections-page">
      <header>
        <h1>Connected applications</h1>
        <p>Review applications with access to your projects and tracks.</p>
        <p>Activity times update about once a minute. Older activity may not be recorded.</p>
      </header>
      <div class="connections-list">
        <p :if={@connections == []}>No applications connected.</p>
        <section
          :for={connection <- @connections}
          id={"connection-#{connection.id}"}
          class="connection-card"
        >
          <div class="row connection-heading">
            <h2>{connection.name}</h2>
            <span class="spacer"></span>
            <form
              :if={connection.active}
              action={"/settings/connections/#{connection.id}/revoke"}
              method="post"
            >
              <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
              <button type="submit" class="ghost">Disconnect</button>
            </form>
            <span :if={!connection.active} class="dim">Disconnected or expired</span>
          </div>
          <p class="mono connection-resource">{connection.resource}</p>
          <dl class="connection-dates">
            <div>
              <dt>Connected</dt><dd><.activity_time value={connection.connected_at} /></dd>
            </div>
            <div>
              <dt>Last used</dt><dd><.activity_time value={connection.last_used_at} /></dd>
            </div>
          </dl>
          <details>
            <summary>Permissions ({length(connection.scopes)})</summary>
            <ul>
              <li :for={scope <- connection.scopes}>{description(scope)}</li>
            </ul>
          </details>
        </section>
      </div>
    </div>
    """
  end

  attr :value, :any, required: true

  defp activity_time(assigns) do
    ~H"""
    <time :if={@value} datetime={DateTime.to_iso8601(@value)}>
      {Calendar.strftime(@value, "%b %d, %Y at %H:%M:%S UTC")}
    </time>
    <span :if={is_nil(@value)}>Not recorded yet</span>
    """
  end

  defp description("projects:read"), do: "List accessible projects and repositories."

  defp description("projects:write"),
    do:
      "Create projects and change owned project settings, including executable setup scripts and agent instructions."

  defp description("tracks:read"),
    do: "Read accessible tracks, transcripts and this client's task results."

  defp description("tracks:write"),
    do: "Create tracks and send prompts that run code using the project's agent subscription."

  defp description("plans:read"), do: "Read plans in projects you belong to."

  defp description("plans:write"),
    do:
      "Create and edit plans and append notes. With tracks:write, explicitly assign work using the project owner's subscription."

  defp description("tracks:cancel"), do: "Cancel this client's queued tasks."
end
