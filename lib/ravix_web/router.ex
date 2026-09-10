defmodule RavixWeb.Router do
  @moduledoc """
  The routes.

  Much shorter than `server/app.ts`, and for one reason: the JSON API
  retired with the SPA. What is left over HTTP is what a browser follows
  rather than fetches (the sign-in round trips, invite links, the health
  check) and the pages, which are one `live_session`. Everything the API
  routes did is now a context function a LiveView calls, behind the same
  three doors (`Ravix.Accounts.Access`).
  """

  use RavixWeb, :router

  pipeline :browser do
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
  end

  pipeline :api do
    plug :accepts, ["json"]
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

    # Signing in is two round trips to GitHub (see `Ravix.Accounts.Auth`).
    # `/api/auth/callback` keeps its exact path: it is the callback URL
    # registered on the GitHub App.
    get "/auth/github", AuthController, :github
    get "/api/auth/callback", AuthController, :callback
    get "/api/auth/install", AuthController, :install
    post "/auth/signout", AuthController, :signout
    get "/preview/:track_id", PreviewController, :open

    # An invite link, of either kind: a browser holding one has no idea
    # which it is and should not need to. The GET only says what the link
    # opens; the POST is what joins, so that `protect_from_forgery` covers it
    # and a link cannot be taken by navigating somebody to it (#16).
    get "/j/:token", AuthController, :join
    post "/j/:token", AuthController, :claim

    # URL selection is shared by the rail and the nested track LiveView.
    live_session :workspace, on_mount: [{RavixWeb.Live.Hooks, :fetch_current_user}] do
      live "/", WorkspaceLive, :home
      live "/login", WorkspaceLive, :login
      live "/home", WorkspaceLive, :projects
      live "/inbox", WorkspaceLive, :inbox
      live "/p/:project", WorkspaceLive, :project
      live "/p/:project/t/:track", WorkspaceLive, :track
    end
  end
end
