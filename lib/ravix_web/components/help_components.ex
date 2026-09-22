defmodule RavixWeb.HelpComponents do
  @moduledoc "In-app instructions for connecting desktop AI clients to Ravix."
  use RavixWeb, :html

  def agent_tooling(assigns) do
    assigns = assign(assigns, :base, Ravix.Config.public_url())

    ~H"""
    <div class="tooling-help">
      <p>
        Use your desktop AI tools to configure projects, open tracks and delegate coding work to Ravix.
      </p>
      <details open>
        <summary>Connect Claude Code with MCP</summary>
        <ol>
          <li>
            Run this command in your desktop terminal: <pre><code>claude mcp add --transport http ravix {@base}/mcp</code></pre>
          </li>
          <li>In Claude Code, open <code>/mcp</code>, choose Ravix and authenticate.</li>
          <li>
            Sign in with GitHub in the browser. Check the application name, callback destination
            and requested permissions, then choose <strong>Allow access</strong>.
          </li>
          <li>Return to Claude Code and ask it to use Ravix.</li>
        </ol>
        <p>Try these prompts:</p>
        <ul>
          <li>“List my Ravix projects and show the settings for my app.”</li>
          <li>
            “Create a track on my app and ask its agent to fix the failing tests. Check back for the result.”
          </li>
          <li>“Update my project's setup script to install its dependencies.”</li>
        </ul>
        <p>
          MCP tools can list repositories, create projects, update settings, open tracks, send
          prompts and read replies. Keep the task ID to check progress. For retries, reuse the
          same request ID and arguments so work is not submitted twice.
        </p>
      </details>
      <details>
        <summary>Drive tracks with an A2A client</summary>
        <p>
          A2A lets another agent submit work to a Ravix track and follow its result.
          Claude Code connects directly through MCP; A2A requires a client or adapter that supports A2A 1.0.
        </p>
        <dl>
          <dt>Agent discovery</dt><dd><code>{@base}/.well-known/agent-card.json</code></dd>
          <dt>A2A endpoint</dt><dd><code>{@base}/a2a</code></dd>
          <dt>OAuth discovery</dt><dd><code>{@base}/.well-known/oauth-authorization-server</code></dd>
        </dl>
        <p>
          Configure the client for OAuth authorization code with PKCE S256 and use the A2A
          endpoint as its resource. Authorize it in the browser. MCP and A2A need separate
          resource tokens; your browser session is not an API credential.
        </p>
        <ol>
          <li>Copy a track ID from its browser URL: <code>/p/PROJECT_ID/t/TRACK_ID</code>.</li>
          <li>
            Send a text message with that ID as <code>contextId</code>
            and a unique <code>messageId</code>.
          </li>
          <li>
            Save the returned task ID. Use <code>GetTask</code>
            to poll or <code>SubscribeToTask</code>
            to stream progress.
          </li>
        </ol>
        <details>
          <summary>Example JSON-RPC request</summary>
          <pre><code>{a2a_example()}</code></pre>
        </details>
        <p>
          To open a new track, omit <code>contextId</code>
          and set <code>params.metadata.ravix.projectId</code>
          to your project ID. Send a new message ID
          in the same context for follow-up work. Project settings are managed through MCP.
        </p>
      </details>
      <details>
        <summary>Permissions, progress and disconnecting</summary>
        <p>
          Connections act as you, within the permissions you approve, across projects and tracks
          you can access, including future ones. They cannot bypass sharing permissions.
          Setup scripts and agent instructions can execute code using the project's agent subscription.
        </p>
        <p>
          Accepted work keeps running after your desktop disconnects. Reconnect with the same
          registered client and task ID. A queued task can be canceled; a running task cannot
          currently be canceled through these tools. A completed task leaves its track open.
        </p>
        <p>
          Open <a href="/settings/connections">Connected applications</a> to review access or
          disconnect an application. Disconnecting revokes access but does not cancel work already accepted.
        </p>
      </details>
      <details>
        <summary>Troubleshooting</summary>
        <ul>
          <li>
            <strong>Authentication expired:</strong>
            let the client refresh its token, or authenticate again.
          </li>
          <li>
            <strong>A tool is missing or access is denied:</strong>
            reconnect with the required scopes and check your project or track membership.
          </li>
          <li>
            <strong>A task is still queued:</strong>
            it may be waiting for the project's machine or another turn. Poll its task ID; do not resubmit with a new ID.
          </li>
          <li>
            <strong>A stream or wait ended:</strong>
            connections rotate after about 55 seconds. Poll or subscribe again; the task continues.
          </li>
          <li>
            <strong>A creation result is unconfirmed:</strong>
            inspect your projects and tracks before retrying with a new request ID.
          </li>
        </ul>
      </details>
    </div>
    """
  end

  defp a2a_example do
    Jason.encode!(
      %{
        jsonrpc: "2.0",
        id: "request-1",
        method: "SendMessage",
        params: %{
          message: %{
            messageId: "desktop-work-1",
            role: "ROLE_USER",
            contextId: "TRACK_ID",
            parts: [%{text: "Fix the failing tests."}]
          },
          configuration: %{returnImmediately: true}
        }
      },
      pretty: true
    )
  end
end
