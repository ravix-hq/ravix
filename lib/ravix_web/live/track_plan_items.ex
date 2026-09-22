defmodule RavixWeb.Live.TrackPlanItems do
  @moduledoc "Assigned item material, including for guests who cannot open the project plan."
  use RavixWeb, :live_component
  alias Ravix.Plans

  @impl true
  def update(assigns, socket), do: {:ok, socket |> assign(assigns) |> load()}

  @impl true
  def handle_event("note", %{"item_id" => id, "body" => body}, socket) do
    with {:ok, items} <- Plans.track_items(socket.assigns.current_user, socket.assigns.track_id),
         true <- Enum.any?(items, &(&1.id == id)),
         {:ok, _} <- Plans.note(socket.assigns.current_user, id, body) do
      {:noreply, load(socket)}
    else
      _ -> {:noreply, assign(socket, items: [], error: "This item is no longer available.")}
    end
  end

  defp load(socket) do
    case Plans.track_items(socket.assigns.current_user, socket.assigns.track_id) do
      {:ok, items} -> assign(socket, items: items, error: nil)
      _ -> assign(socket, items: [], error: "This track is no longer available.")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <p :if={@error} role="alert">{@error}</p>
      <details :for={item <- @items} class="plan-item">
        <summary>Assigned item: {item.title}</summary>
        <div class="md">{Phoenix.HTML.raw(RavixWeb.Markdown.render(item.brief))}</div>
        <p>Acceptance: {item.acceptance}</p>
        <ul>
          <li :for={note <- item.notes}>{note.created_by_login}: {note.body}</li>
        </ul>
        <.form for={%{}} id={"track-note-#{item.id}"} phx-submit="note" phx-target={@myself}>
          <input type="hidden" name="item_id" value={item.id} />
          <label for={"track-note-body-#{item.id}"}>Add an item note</label>
          <textarea id={"track-note-body-#{item.id}"} name="body" required maxlength="10000"></textarea>
          <button type="submit">Add note</button>
        </.form>
      </details>
    </div>
    """
  end
end
