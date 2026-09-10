defmodule RavixWeb.Layouts do
  @moduledoc """
  The two layouts.

  `root.html.heex` is the document: the meta tags, the favicon, the title
  (`Ravix`, with no suffix, because the tab is the product's name and not a
  page in it), the stylesheet, the script, and the inline theme bootstrap
  that paints the saved palette before the stylesheet does. `app/1` is what
  every page renders inside it, and it is deliberately nothing: no chrome, no
  nav bar, no progress bar. The SPA this replaces drew its own frame (the
  rail, the stage, the inspector) as the page, and the LiveView pages do the
  same, so a layout with furniture of its own would be furniture in the way.

  The one thing the app layout adds is the toasts, because errors in Ravix
  are toasts and never a replaced screen (see `App.tsx`): the flash, and the
  two the LiveView runtime raises itself when the socket drops.
  """
  use RavixWeb, :html

  embed_templates "layouts/*"

  @doc """
  The app layout: the page, and the toasts over it.

      <Layouts.app flash={@flash}>
        <div class="app">...</div>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    {render_slot(@inner_block)}
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The flash as toasts, plus the two the socket raises on its own.

  The reconnect toasts are hidden until the runtime flips `phx-disconnected`,
  and they are `bad` because a dropped socket is the one error a LiveView
  page cannot recover from without help.

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="toasts" aria-live="polite">
      <.toast :if={msg = Phoenix.Flash.get(@flash, :info)} id="flash-info" kind={:info}>
        {msg}
      </.toast>
      <.toast :if={msg = Phoenix.Flash.get(@flash, :error)} id="flash-error" kind={:error}>
        {msg}
      </.toast>
      <.toast
        id="client-error"
        kind={:error}
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        dismiss={nil}
        hidden
      >
        We can't find the internet. Attempting to reconnect.
      </.toast>
      <.toast
        id="server-error"
        kind={:error}
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        dismiss={nil}
        hidden
      >
        Something went wrong on the server. Attempting to reconnect.
      </.toast>
    </div>
    """
  end
end
