defmodule RavixWeb.Live.AgentHealth do
  @moduledoc "Owner-funded runtime status, shared by the project overview and track composer."
  use RavixWeb, :live_component

  alias Ravix.{Accounts, Projects}
  alias RavixWeb.Live.Hooks

  @impl true
  def mount(socket), do: {:ok, assign(socket, health: nil, refused: false)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    user = socket.assigns.current_user
    id = socket.assigns.project_id
    {:ok, traced_async(socket, :health, fn -> Projects.agent_health(user, id) end)}
  end

  @impl true
  def handle_async(:health, {:ok, response}, socket) do
    Hooks.component(socket, fn ->
      # A membership can disappear while Fountain's answer is in flight.
      case Projects.visible?(socket.assigns.current_user, socket.assigns.project_id) do
        false -> {:noreply, assign(socket, health: nil)}
        _ -> {:noreply, assign(socket, health: health(response))}
      end
    end)
  end

  def handle_async(:health, _, socket), do: {:noreply, socket}

  @impl true
  def handle_event("reconnect", _, socket) do
    # Re-establish ownership at the event boundary; a forged click cannot
    # open someone else's funding form.
    user = Accounts.session_user(socket.assigns.session_hash)

    with %Accounts.User{} <- user,
         {:ok, project} <- Ravix.Accounts.Access.project_of(user, socket.assigns.project_id) do
      send(self(), {:reconnect_agent, project.id})
    end

    {:noreply, socket}
  end

  defp health({:ok, health}), do: health
  defp health(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@health && (@health.usable? == false || @refused)}
        class="welcome-warning"
        role="status"
        id={@id <> "-banner"}
      >
        <p>
          This project runs on {@health.owner_login}'s {RavixWeb.AgentName.label(@health.runtime)}.
          <%= if @refused do %>
            Sending is paused because the owner's agent connection was refused. Reconnect, then retry the saved message.
          <% else %>
            The owner's agent connection appears to be missing. Sending may be paused until it is reconnected.
          <% end %>
        </p>
        <button
          :if={@health.owner?}
          type="button"
          class="ghost"
          phx-click="reconnect"
          phx-target={@myself}
        >
          Reconnect {RavixWeb.AgentName.label(@health.runtime)}
        </button>
        <p :if={!@health.owner?}>
          Ask {@health.owner_login} to reconnect {RavixWeb.AgentName.label(@health.runtime)}.
        </p>
      </div>
    </div>
    """
  end
end
