defmodule RavixWeb.Live.TrackPlanItems do
  @moduledoc "Compact assigned material, including for guests without project access."
  use RavixWeb, :live_component
  alias Ravix.Plans

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:expanded, fn -> false end)
     |> assign_new(:detail, fn -> nil end)
     |> assign_new(:error, fn -> nil end)
     |> assign(items: Enum.sort_by(assigns.summary.items, &order/1))}
  end

  @impl true
  def handle_event(event, params, socket) do
    case Ravix.Accounts.Access.track_access(socket.assigns.current_user, socket.assigns.track_id) do
      {:ok, _} -> event(event, params, socket)
      _ -> {:noreply, assign(socket, items: [], error: "This track is no longer available.")}
    end
  end

  defp event("toggle", _, socket),
    do: {:noreply, assign(socket, expanded: !socket.assigns.expanded)}

  defp event("detail", %{"id" => id}, socket),
    do: {:noreply, assign(socket, detail: if(socket.assigns.detail != id, do: id))}

  defp event("note", %{"item_id" => id, "body" => body}, socket) do
    with {:ok, items} <- Plans.track_items(socket.assigns.current_user, socket.assigns.track_id),
         true <- Enum.any?(items, &(&1.id == id)),
         {:ok, _} <- Plans.note(socket.assigns.current_user, id, body) do
      send(self(), :refresh_plan_items)
      {:noreply, assign(socket, error: nil)}
    else
      _ -> {:noreply, assign(socket, items: [], error: "This item is no longer available.")}
    end
  end

  defp order(item) do
    group =
      case item.status do
        status when status in [:in_progress, :in_review] -> 0
        status when status in [:done, :closed_without_merge] -> 2
        _ -> 1
      end

    {group, item.position}
  end

  defp label(:unassigned), do: "Unassigned"
  defp label(:ready), do: "Unassigned"
  defp label(:in_progress), do: "In progress"
  defp label(:in_review), do: "In review"
  defp label(:done), do: "Merged"
  defp label(:closed_without_merge), do: "Closed without merge"
  defp label(:blocked), do: "Blocked"

  defp progress(items) do
    done = Enum.count(items, &(&1.status == :done))
    if done == length(items), do: "All plan items done", else: "#{done} of #{length(items)} done"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="track-plan-items">
      <p :if={@error} role="alert">{@error}</p>
      <div :if={@items != []} class="track-plan-summary">
        <.link
          :if={@summary.plan}
          navigate={@summary.plan.url}
          title={@summary.plan.title}
          class="track-plan-title"
        >
          Plan · {@summary.plan.title}
        </.link>
        <span :if={!@summary.plan} class="track-plan-title">Plan items</span>
        <RavixWeb.PlanProgress.summary progress={
          if @summary.plan, do: @summary.plan.progress, else: @summary.progress
        } />
        <button
          type="button"
          class="ghost track-plan-toggle"
          phx-click="toggle"
          phx-target={@myself}
          aria-expanded={to_string(@expanded)}
          aria-controls={"#{@id}-list"}
        >
          {progress(@items)} <span aria-hidden="true">{if @expanded, do: "▾", else: "▸"}</span>
        </button>
      </div>
      <ul :if={@items != []} id={"#{@id}-list"} class="track-plan-list" hidden={!@expanded}>
        <li :for={item <- @items} :if={@expanded} id={"assigned-item-#{item.id}"}>
          <div class="track-plan-item-row">
            <span class={"chip plan-status plan-status-#{item.status}"}>{label(item.status)}</span>
            <button
              type="button"
              class="ghost track-plan-item-title"
              title={item.title}
              phx-click="detail"
              phx-value-id={item.id}
              phx-target={@myself}
              aria-expanded={to_string(@detail == item.id)}
              aria-controls={"assigned-detail-#{item.id}"}
            >{item.title}</button>
            <.link
              :if={item.pull && item.pull.url}
              href={item.pull.url}
              target="_blank"
              rel="noopener noreferrer"
              class="track-plan-pr"
              aria-label={"Pull request ##{item.pull.number}"}
            >#{item.pull.number}</.link>
          </div>
          <div id={"assigned-detail-#{item.id}"} hidden={@detail != item.id}>
            <div :if={@detail == item.id} class="track-plan-detail">
              <p :if={!item.status_available} class="hint">PR status is temporarily unavailable.</p>
              <div class="md">{RavixWeb.Markdown.render_safe(item.brief)}</div>
              <p :if={item.acceptance != ""}><strong>Acceptance:</strong> {item.acceptance}</p>
              <ul :if={item.notes != []}>
                <li :for={note <- item.notes}>{note.created_by_login}: {note.body}</li>
              </ul>
              <.form for={%{}} id={"track-note-#{item.id}"} phx-submit="note" phx-target={@myself}>
                <input type="hidden" name="item_id" value={item.id} />
                <label for={"track-note-body-#{item.id}"}>Add an item note</label>
                <textarea id={"track-note-body-#{item.id}"} name="body" required maxlength="10000"></textarea>
                <button type="submit">Add note</button>
              </.form>
            </div>
          </div>
        </li>
      </ul>
    </div>
    """
  end
end
