defmodule RavixWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use RavixWeb, :controller
      use RavixWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  @doc "What `Plug.Static` serves, as the undigested names on disk."
  @spec static_paths() :: [String.t()]
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt theme.js)

  @doc """
  The root-level entries of `static_paths/0`, as prefixes.

  `mix phx.digest` renames a file at the root --- `theme.js` on disk becomes
  `theme-<digest>.js` --- and `Plug.Static`'s `:only` compares the request's
  *first segment* against its list exactly, so the digested name is not in it
  and the request falls through to the router, which 404s. A file inside a
  directory is unaffected, because digesting changes the name after the
  segment being matched; that is why this was only ever true of the three
  files at the root.

  It went unseen because it cannot happen where it would be noticed. `~p`
  only rewrites to the digested name when a manifest exists, so in dev and in
  test the tag says `/theme.js`, which is in `:only` and is served; and
  `raise_on_missing_only`, which exists to catch exactly this, is on in dev,
  where there is nothing to catch. Production served the palette bootstrap as
  a 404 and every hard load painted the default theme until LiveView
  connected. `browser/workspace.spec.js` is where that is now asserted,
  because the browser suite is the one that runs a digested build.

  `:only_matching` is `Plug.Static`'s own answer for this --- its docs name
  serving digested files at the root as the case it is for.
  """
  @spec static_prefixes() :: [String.t()]
  def static_prefixes do
    static_paths()
    |> Enum.filter(&(Path.extname(&1) != ""))
    |> Enum.map(&Path.rootname/1)
  end

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      # Every page turns the same three tagged results into the same three
      # socket changes; see `RavixWeb.Live.Result`.
      import RavixWeb.Live.Result

      # `start_async/3` with the trace carried into the task; see
      # `RavixWeb.Live.Async`.
      import RavixWeb.Live.Async

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      # A component's events never pass through the page's session hooks, so
      # `handle_event/3` is wrapped here; see the moduledoc of
      # `RavixWeb.Live.Hooks`. The page must pass `session_hash`.
      @before_compile RavixWeb.Live.Hooks

      import RavixWeb.Live.Result
      import RavixWeb.Live.Async

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import RavixWeb.CoreComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias RavixWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: RavixWeb.Endpoint,
        router: RavixWeb.Router,
        statics: RavixWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
