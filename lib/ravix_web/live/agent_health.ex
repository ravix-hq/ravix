defmodule RavixWeb.Live.AgentHealth do
  @moduledoc "Payer-funded runtime status and pauses, shared by the project overview and track composer."
  use RavixWeb, :live_component

  alias Ravix.{Accounts, Projects, Tracks}
  alias RavixWeb.Live.Hooks

  @impl true
  def mount(socket), do: {:ok, assign(socket, health: nil, refused: false)}

  @impl true
  def update(assigns, socket) do
    key = {assigns[:track_id], assigns[:thread_id]}

    socket =
      if socket.assigns[:health_key] != key,
        do: assign(socket, health: nil, health_key: key),
        else: socket

    socket = assign(socket, assigns)
    user = socket.assigns.current_user
    project_id = socket.assigns.project_id
    {:ok, traced_async(socket, :health, fn -> read_health(user, project_id, key) end)}
  end

  @impl true
  def handle_async(:health, {:ok, response}, socket) do
    Hooks.component(socket, fn ->
      # A membership can disappear while Fountain's answer is in flight.
      case visible?(socket) do
        false -> {:noreply, assign(socket, health: nil)}
        _ -> {:noreply, assign(socket, health: health(response))}
      end
    end)
  end

  def handle_async(:health, _, socket), do: {:noreply, socket}

  @impl true
  def handle_event("reconnect", _, %{assigns: %{health: %{billing: :creator} = health}} = socket) do
    # A creator-billed track's payer reconnects their own account; the
    # dialog it opens only ever writes the signed-in person's credentials.
    user = Accounts.session_user(socket.assigns.session_hash)

    with %Accounts.User{} <- user,
         true <- payer?(user, socket) do
      send(self(), {:reconnect_own_agent, health.runtime})
    end

    {:noreply, socket}
  end

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

  # "Try again": the payer lifts a pause on this harness of the track.
  def handle_event("resume", _, %{assigns: %{health: %{billing: :creator} = health}} = socket) do
    user = Accounts.session_user(socket.assigns.session_hash)
    {track_id, _thread_id} = socket.assigns.health_key

    socket =
      with %Accounts.User{} <- user,
           :ok <- Tracks.resume_billing(user, track_id, health.runtime) do
        key = socket.assigns.health_key
        traced_async(socket, :health, fn -> read_health(user, socket.assigns.project_id, key) end)
      else
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("resume", _, socket), do: {:noreply, socket}

  defp payer?(user, socket) do
    case socket.assigns.health_key do
      {track_id, thread_id} when is_binary(track_id) ->
        match?({:ok, %{owner?: true}}, Tracks.agent_health(user, track_id, thread_id))

      _ ->
        false
    end
  end

  defp read_health(user, _project_id, {track_id, thread_id}) when is_binary(track_id),
    do: Tracks.agent_health(user, track_id, thread_id)

  defp read_health(user, project_id, _), do: Projects.agent_health(user, project_id)

  defp visible?(socket) do
    case socket.assigns[:health_key] do
      {track_id, thread_id} when is_binary(track_id) ->
        match?(
          {:ok, _},
          Ravix.Accounts.Access.thread_access(socket.assigns.current_user, track_id, thread_id)
        )

      _ ->
        Projects.visible?(socket.assigns.current_user, socket.assigns.project_id)
    end
  end

  defp health({:ok, health}), do: health
  defp health(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={
          @health &&
            (@health.usable? == false || @refused || @health.exhausted_until ||
               Map.get(@health, :pause))
        }
        class="welcome-warning"
        role="status"
        id={@id <> "-banner"}
      >
        <p :if={Map.get(@health, :pause)} id={@id <> "-pause"}>{@health.pause.message}</p>
        <button
          :if={Map.get(@health, :pause) && @health.owner?}
          type="button"
          class="ghost"
          phx-click="resume"
          phx-target={@myself}
        >
          Try again
        </button>
        <p :if={@health.exhausted_until && !Map.get(@health, :pause)}>
          {@health.owner_login}'s ChatGPT usage resets at
          <.provider_time id={@id <> "-resets"} value={@health.exhausted_until} />.
        </p>
        <p :if={
          !@health.exhausted_until && !Map.get(@health, :pause) &&
            Map.get(@health, :scope) == :thread
        }>
          <%= if @health.usable? == false do %>
            This thread uses {RavixWeb.AgentName.label(@health.runtime)}, which {@health.owner_login} has disconnected.
          <% else %>
            This thread’s {RavixWeb.AgentName.label(@health.runtime)} connection was refused. Reconnect, then retry the saved message.
          <% end %>
        </p>
        <p :if={!@health.exhausted_until && Map.get(@health, :scope) != :thread}>
          <%= if @health.owner? do %>
            <%= if @refused do %>
              Sending is paused because your agent connection was refused. Reconnect, then retry your saved prompts.
            <% else %>
              Your agent connection appears to be missing. Connect your subscription or API key to resume.
            <% end %>
          <% else %>
            This project runs on @{@health.owner_login}'s {RavixWeb.AgentName.label(@health.runtime)}.
            <%= if @refused do %>
              Sending is paused because their agent connection was refused. Your saved prompts can be retried after they reconnect.
            <% else %>
              Their agent connection appears to be missing. Sending may be paused until they reconnect their subscription or API key.
            <% end %>
          <% end %>
        </p>
        <button
          :if={@health.owner? && !@health.exhausted_until}
          type="button"
          class="ghost"
          phx-click="reconnect"
          phx-target={@myself}
        >
          Reconnect {RavixWeb.AgentName.label(@health.runtime)}
        </button>
        <p :if={!@health.owner? && !@health.exhausted_until}>
          Ask {@health.owner_login} to reconnect {RavixWeb.AgentName.label(@health.runtime)}.
        </p>
      </div>
    </div>
    """
  end
end
