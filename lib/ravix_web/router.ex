defmodule RavixWeb.Router do
  @moduledoc """
  The routes.

  Browser pages use scoped contexts behind the three access doors in
  `Ravix.Accounts.Access`. MCP and A2A expose the same operations through
  resource-bound OAuth grants; browser sessions handle consent and revocation.
  """

  use RavixWeb, :router

  pipeline :browser do
    plug :unknown_page_format
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RavixWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' https: data: blob:; connect-src 'self' ws: wss:; frame-src http: https:; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"
    }

    plug RavixWeb.Plugs.CurrentUser
    plug :unknown_page
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :image do
    plug :fetch_session
    plug :protect_from_forgery
    plug RavixWeb.Plugs.CurrentUser
  end

  scope "/", RavixWeb do
    pipe_through :image

    get "/tracks/:track/threads/:thread/turns/:turn/images/:position",
        PromptImageController,
        :show
  end

  scope "/", RavixWeb do
    pipe_through :api
    get "/.well-known/oauth-authorization-server", ToolingOAuthController, :metadata
    get "/.well-known/oauth-protected-resource/:resource", ToolingOAuthController, :resource
    post "/oauth/register", ToolingOAuthController, :register
    post "/oauth/token", ToolingOAuthController, :token
    post "/oauth/revoke", ToolingOAuthController, :revoke
    get "/.well-known/agent-card.json", ToolingController, :card
    post "/mcp", ToolingController, :mcp
    get "/mcp", ToolingController, :unsupported
    delete "/mcp", ToolingController, :end_session
    post "/a2a", ToolingController, :a2a
  end

  # Not pages, and not behind the session. `/readyz` is what Render's health
  # check reads and so what gates the rotation; `/healthz` only says the process
  # is up. See `RavixWeb.HealthController`.
  get "/healthz", RavixWeb.HealthController, :show
  get "/readyz", RavixWeb.HealthController, :ready

  scope "/api", RavixWeb do
    pipe_through :api
    post "/tracks/:track_id/preview/agent", PreviewController, :agent
  end

  scope "/", RavixWeb do
    pipe_through :browser

    get "/oauth/authorize", ToolingOAuthController, :authorize
    post "/oauth/authorize", ToolingOAuthController, :consent
    post "/settings/connections/:id/revoke", ToolingOAuthController, :disconnect

    # Signing in is two round trips to GitHub (see `Ravix.Accounts.Auth`).
    # `/api/auth/callback` keeps its exact path: it is the callback URL
    # registered on the GitHub App.
    get "/auth/github", AuthController, :github
    get "/api/auth/callback", AuthController, :callback
    get "/api/auth/install", AuthController, :install
    # Connecting GitHub to a workspace (ADR 0009 phase 4b); GitHub returns
    # to `/api/auth/callback` above.
    get "/w/:workspace/github/connect", WorkspaceGitHubController, :connect
    post "/auth/signout", AuthController, :signout
    get "/preview/:track_id", PreviewController, :open

    # An invite link, of either kind: a browser holding one has no idea
    # which it is and should not need to. The GET only says what the link
    # opens; the POST is what joins, so that `protect_from_forgery` covers it
    # and a link cannot be taken by navigating somebody to it (#16).
    get "/j/:token", AuthController, :join
    post "/j/:token", AuthController, :claim

    # Settings that moved into the settings frame (RAV-72), and the bare
    # addresses of it; each lands on a section.
    get "/settings", SettingsRedirectController, :personal
    get "/settings/connections", SettingsRedirectController, :connections
    get "/w/:workspace", SettingsRedirectController, :workspace
    get "/w/:workspace/settings", SettingsRedirectController, :workspace
    get "/p/:project/settings", SettingsRedirectController, :project

    # URL selection is shared by the rail and the nested track LiveView.
    #
    # There is no marketing page. `/` is the workspace for somebody signed in
    # and a redirect to `/login` for anybody else; `/login` is the reverse, so
    # every one of these paths lands a browser on the only thing it can use.
    # `WorkspaceLive.handle_params/3` decides, because the session is what the
    # answer turns on and it is one LiveView either way.
    # `StaleAssets` first: a tab rejoining after a deploy is offered a reload
    # rather than left with markup its stylesheet predates (RAV-138).
    live_session :workspace,
      on_mount: [RavixWeb.Live.StaleAssets, {RavixWeb.Live.Hooks, :fetch_current_user}] do
      live "/", WorkspaceLive, :home
      live "/login", WorkspaceLive, :login
      live "/home", WorkspaceLive, :projects
      live "/schedules", WorkspaceLive, :schedules
      live "/inbox", WorkspaceLive, :inbox
      live "/p/:project", WorkspaceLive, :project
      live "/p/:project/plans", WorkspaceLive, :plans
      live "/p/:project/t/:track", WorkspaceLive, :track
      # Settings pages in the shell, one URL a section; see
      # `RavixWeb.Live.Settings`. A workspace's are behind
      # RAVIX_WORKSPACE_ACCESS (ADR 0009).
      live "/settings/:section", WorkspaceLive, :user_settings
      live "/w/:workspace/settings/:section", WorkspaceLive, :workspace_settings
      live "/p/:project/settings/:section", WorkspaceLive, :project_settings

      # The first visit. The same `live_session`, so the workspace can send
      # somebody here and be sent back without a page load in between.
      live "/welcome", OnboardingLive, :intro
      live "/welcome/agent", OnboardingLive, :agent
      live "/welcome/github", OnboardingLive, :github
      live "/welcome/project", OnboardingLive, :project

      # Anything else, last: for somebody signed in, "Page not found" in the
      # app shell rather than a page with no way on (RAV-100). See
      # `unknown_page/2` for everybody else.
      live "/*unknown_path", WorkspaceLive, :not_found
    end
  end

  # The catch-all above is a page, so only a browser asking for HTML gets it;
  # anything else (an OAuth or MCP client probing for a document) keeps the
  # plain 404 that falls back cleanly. Runs before `accepts`, which would
  # otherwise answer such a client 406.
  defp unknown_page_format(%{path_params: %{"unknown_path" => _}} = conn, _opts) do
    if wants_html?(Plug.Conn.get_req_header(conn, "accept")),
      do: conn,
      else: raise(Phoenix.Router.NoRouteError, conn: conn, router: __MODULE__)
  end

  defp unknown_page_format(conn, _opts), do: conn

  # As `accepts/2` reads it: no Accept, or one naming HTML or anything.
  defp wants_html?([]), do: true
  defp wants_html?(accept), do: Enum.any?(accept, &(&1 =~ ~r{text/html|\*/\*}))

  # A stranger has no shell to be shown and gets the static 404 page
  # (`RavixWeb.ErrorHTML`); somebody signed in gets the shell's, still as a
  # 404, which is what the dead render sends.
  defp unknown_page(%{path_params: %{"unknown_path" => _}} = conn, _opts) do
    if conn.assigns[:current_user],
      do: Plug.Conn.put_status(conn, :not_found),
      else: raise(Phoenix.Router.NoRouteError, conn: conn, router: __MODULE__)
  end

  defp unknown_page(conn, _opts), do: conn
end
