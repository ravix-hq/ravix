defmodule RavixWeb.Live.ConnectionsPanel do
  @moduledoc "The signed-in person's OAuth connections inside the workspace."
  use RavixWeb, :live_component
  alias Ravix.Tooling.OAuth

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket |> assign(assigns) |> assign(connections: OAuth.connections(assigns.current_user))}
  end

  @impl true
  def render(assigns), do: RavixWeb.ToolingOAuthHTML.connections(assigns)
end
