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
        <p>
          This connection can act on workspaces, projects and tracks you can access, including future ones:
        </p>
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
          You can disconnect this application in <a href="/settings/connected-apps">Connected applications</a>.
        </p>
      </main>
    </div>
    """
  end

  def connections(assigns) do
    ~H"""
    <div id="connections-panel" class={["connections-page", !assigns[:framed] && "inbox"]}>
      <header>
        <h1 :if={!assigns[:framed]}>Connected applications</h1>
        <p>Review applications with access to your workspaces, projects and tracks.</p>
        <p>
          Each is named by its client and when it connected, in your time. Last use updates about once a minute; older use may not be recorded.
        </p>
      </header>
      <div class="connections-list">
        <p :if={@connections == []}>No applications connected.</p>
        <section
          :for={connection <- @connections}
          id={"connection-#{connection.id}"}
          class="connection-card"
        >
          <div class="row connection-heading">
            <h2>
              <span class="connection-name">{connection.name}</span>
              <span class="connection-meta" id={"connection-#{connection.id}-meta"}>
                <span aria-hidden="true">·</span>
                <span>
                  connected
                  <.local_time
                    id={"connection-#{connection.id}-connected"}
                    at={connection.connected_at}
                    title_prefix="Connected "
                  />
                </span>
                <span aria-hidden="true">·</span>
                <span :if={connection.last_used_at}>
                  last used
                  <time
                    id={"connection-#{connection.id}-used"}
                    phx-hook="RelativeTime"
                    data-style="ago"
                    data-title-prefix="Last used "
                    datetime={DateTime.to_iso8601(connection.last_used_at)}
                    title={"Last used " <> RavixWeb.LocalTime.full(connection.last_used_at, nil)}
                  >{RavixWeb.LocalTime.ago_words(connection.last_used_at)}</time>
                </span>
                <span :if={!connection.last_used_at}>not used yet</span>
              </span>
            </h2>
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

  defp description("workspaces:read"),
    do: "Read workspace memberships, repository catalogs and your personal sidebar sections."

  defp description("workspaces:write"),
    do:
      "Create and rename workspaces, manage members and GitHub connections, add repository projects, move your owned projects between workspaces, and organize your sidebar. Adding repository projects uses the project payer's subscription. Your workspace role still limits each action."

  defp description("projects:read"), do: "List accessible projects and repositories."

  defp description("projects:write"),
    do:
      "Create projects and read or change owned project settings and run defaults, including executable setup scripts, run commands and agent instructions."

  defp description("tracks:read"),
    do:
      "Read accessible tracks, transcripts, preview and run configuration, status and logs, and this client's task results."

  defp description("tracks:write"),
    do:
      "Create tracks and send prompts that run code using the project's agent subscription. Configure, start, restart and stop track previews and run scripts on their machines."

  defp description("plans:read"), do: "Read plans in projects you belong to."

  defp description("plans:write"),
    do:
      "Create and edit plans and append notes. With tracks:write, explicitly assign work using the project owner's subscription."

  defp description("tracks:cancel"), do: "Cancel this client's queued tasks."
end
