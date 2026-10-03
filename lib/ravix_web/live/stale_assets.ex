defmodule RavixWeb.Live.StaleAssets do
  @moduledoc """
  A tab left open across a deploy is told so, and offered a reload (RAV-138).

  A deploy restarts the server and every open socket reconnects to the new
  release, which renders its markup into a page still holding the old
  release's CSS and JavaScript. A rule the old stylesheet predates is simply
  missing: the Share button's viewer avatar drew at its full size over the
  track header, because `.track-viewer img` was new.

  `Phoenix.LiveView.static_changed?/1` answers whether the
  `phx-track-static` assets in the root layout (`app.css`, `app.js`) are
  ones this release no longer serves. That answer is the
  `:static_changed?` assign, and `RavixWeb.Layouts.app/1` draws the
  "Ravix was updated" bar from it.

  The page is not reloaded for the person. A reload drops an unsent
  composer draft and closes an open dialog, and only the person knows
  whether either is there. The bar's Reload is a server event rather than
  script: the script it would run is the stale one, which may not have it.
  The event is answered here, before the page sees it, with a redirect to
  the URL the page is on, so every page in the `live_session` gets it.

  Without a digest manifest (dev and test) `static_changed?/1` is always
  false, so the bar only appears on a release built by `mix assets.deploy`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, redirect: 2, static_changed?: 1]

  alias Phoenix.LiveView.Socket

  @spec on_mount(:default, map(), map(), Socket.t()) :: {:cont, Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    stale? = stale?(socket)
    socket = assign(socket, :static_changed?, stale?)

    if stale? do
      {:cont,
       socket
       |> attach_hook(:stale_assets_uri, :handle_params, &remember_uri/3)
       |> attach_hook(:stale_assets_reload, :handle_event, &reload/3)}
    else
      {:cont, socket}
    end
  end

  # Only a root LiveView has connect params to ask; a nested one never is.
  defp stale?(%Socket{parent_pid: nil} = socket), do: static_changed?(socket)
  defp stale?(%Socket{}), do: false

  defp remember_uri(_params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    {:cont, assign(socket, :stale_assets_path, if(query, do: "#{path}?#{query}", else: path))}
  end

  defp reload("reload_stale_assets", _params, socket),
    do: {:halt, redirect(socket, to: socket.assigns[:stale_assets_path] || "/")}

  defp reload(_event, _params, socket), do: {:cont, socket}
end
