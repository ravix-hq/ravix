defmodule RavixWeb.Live.PersonalSettings do
  @moduledoc """
  The signed-in person's own settings, `/settings/:section`, in the
  settings frame (`RavixWeb.Live.Settings`, RAV-72). One section so far:
  Connected apps, the OAuth connections that were `/settings/connections`,
  moved in unchanged. Disconnecting is still a plain form post to
  `RavixWeb.ToolingOAuthController`, which comes back here.

  Beside it the nav lists the current workspace's settings, when there is
  one, so a person moves between the two without the switcher.
  """
  use RavixWeb, :live_component
  alias Ravix.Tooling.OAuth
  alias RavixWeb.Live.Settings

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket |> assign(assigns) |> assign(connections: OAuth.connections(assigns.current_user))}
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
        <RavixWeb.ToolingOAuthHTML.connections connections={@connections} framed />
      </Settings.frame>
    </div>
    """
  end
end
