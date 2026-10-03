defmodule RavixWeb.Live.RoutinesPanel do
  @moduledoc "Webhook management alongside schedules; every event rechecks session and scoped access."
  use RavixWeb, :live_component
  alias Ravix.Routines
  alias Ravix.Routines.Routine
  alias RavixWeb.Live.RoutineCredential

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket, editing: nil, form: blank_form(), error: nil, credential: nil, history: nil)}

  @impl true
  def update(assigns, socket), do: {:ok, socket |> assign(assigns) |> load()}

  @impl true
  def handle_event("save", %{"routine" => attrs}, socket) do
    %{current_user: user, editing: editing} = socket.assigns

    result =
      if editing,
        do: Routines.update(user, editing, attrs),
        else: Routines.create(user, attrs["project_id"], attrs)

    case result do
      {:ok, row, token} ->
        saved(socket, {row.id, %RoutineCredential{value: token}})

      {:ok, _} ->
        saved(socket, nil)

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :routine), credential: nil)}

      {:error, reason} ->
        refuse(socket, reason)
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Routines.get(socket.assigns.current_user, id) do
      {:ok, row} ->
        {:noreply,
         assign(socket,
           editing: id,
           form: to_form(Routine.changeset(row, %{}), as: :routine),
           credential: nil,
           error: nil
         )}

      {:error, reason} ->
        refuse(socket, reason)
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with {:ok, row} <- Routines.get(socket.assigns.current_user, id),
         {:ok, _} <- Routines.update(socket.assigns.current_user, id, %{enabled: not row.enabled}) do
      {:noreply, socket |> assign(credential: nil) |> load()}
    else
      {:error, reason} -> refuse(socket, reason)
    end
  end

  def handle_event("rotate", %{"id" => id}, socket) do
    case Routines.rotate(socket.assigns.current_user, id) do
      {:ok, row, token} ->
        {:noreply,
         socket
         |> assign(credential: {row.id, %RoutineCredential{value: token}}, error: nil)
         |> load()}

      {:error, reason} ->
        refuse(socket, reason)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Routines.delete(socket.assigns.current_user, id) do
      {:ok, _} -> saved(socket, nil)
      {:error, reason} -> refuse(socket, reason)
    end
  end

  def handle_event("history", %{"id" => id}, socket) do
    case Routines.history(socket.assigns.current_user, id) do
      {:ok, rows} -> {:noreply, assign(socket, history: {id, rows}, credential: nil, error: nil)}
      {:error, reason} -> refuse(socket, reason)
    end
  end

  def handle_event("cancel", _, socket), do: saved(socket, nil)
  def handle_event("dismiss", _, socket), do: {:noreply, assign(socket, credential: nil)}

  def handle_event("refresh", _, socket),
    do: {:noreply, socket |> assign(credential: nil, history: nil) |> load()}

  defp saved(socket, credential),
    do:
      {:noreply,
       socket
       |> assign(
         editing: nil,
         form: blank_form(),
         credential: credential,
         error: nil,
         history: nil
       )
       |> load()}

  defp refuse(socket, reason),
    do:
      {:noreply,
       socket
       |> assign(error: RavixWeb.Error.from(reason).message, credential: nil, history: nil)
       |> load()}

  defp blank_form, do: to_form(%{}, as: :routine)

  defp load(socket) do
    rows = Routines.list(socket.assigns.current_user)
    ids = Enum.map(rows, & &1.id)
    socket = assign(socket, routines: rows)

    socket =
      if socket.assigns.editing && socket.assigns.editing not in ids,
        do: assign(socket, editing: nil, form: blank_form()),
        else: socket

    socket =
      case socket.assigns.credential do
        {id, _} -> if id in ids, do: socket, else: assign(socket, credential: nil)
        _ -> socket
      end

    case socket.assigns.history do
      {id, _} -> if id in ids, do: socket, else: assign(socket, history: nil)
      _ -> socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="routines-panel" aria-labelledby="routines-title">
      <div class="row">
        <h2 id="routines-title">Webhook routines</h2><span class="spacer"></span><button
          class="ghost"
          phx-click="refresh"
          phx-target={@myself}
        >Reload routines</button>
      </div>
      <p>A saved prompt that opens a fresh project track when an authenticated JSON event arrives.</p>
      <p :if={@error} role="alert">{@error}</p>
      <div :if={@credential} id="routine-credential" class="schedule-card">
        <p>Save this credential now. It is shown once; rotation revokes the previous credential.</p>
        <code style="overflow-wrap:anywhere">{elem(@credential, 1).value}</code>
        <p>POST {Ravix.Config.public_url()}/api/routines/{elem(@credential, 0)}/webhook</p>
        <p>
          Use Authorization: Bearer &lt;credential&gt;, Content-Type: application/json and a unique Idempotency-Key header. JSON objects up to 32 KiB.
        </p>
        <button class="ghost" phx-click="dismiss" phx-target={@myself}>Dismiss credential</button>
      </div>
      <div class="schedules-layout">
        <section class="schedule-editor">
          <h3>{if @editing, do: "Edit routine", else: "New webhook routine"}</h3>
          <.form for={@form} id="routine-form" phx-submit="save" phx-target={@myself}>
            <.input field={@form[:name]} label="Name" required maxlength="100" />
            <.input
              field={@form[:project_id]}
              label="Project"
              type="select"
              required
              disabled={not is_nil(@editing)}
              prompt="Select a project"
              options={for p <- @projects, p.access != :tracks, do: {p.display_name, p.id}}
            />
            <.input
              field={@form[:prompt]}
              label="Saved prompt"
              type="textarea"
              required
              maxlength="15000"
              rows="5"
            />
            <button type="submit" class="primary" phx-disable-with="Saving…">{if @editing,
              do: "Save routine",
              else: "Create routine"}</button>
            <button :if={@editing} type="button" class="ghost" phx-click="cancel" phx-target={@myself}>Cancel</button>
          </.form>
        </section>
        <section class="schedule-list" aria-label="Your webhook routines">
          <p :if={@routines == []}>No webhook routines yet.</p>
          <article :for={row <- @routines} id={"routine-#{row.id}"} class="schedule-card">
            <h3>{row.name} · {if row.enabled, do: "Active", else: "Paused"}</h3>
            <p class="schedule-prompt">{row.prompt}</p>
            <p style="overflow-wrap:anywhere">POST /api/routines/{row.id}/webhook</p>
            <div class="row schedule-controls">
              <button
                :for={
                  {event, label} <- [
                    {"edit", "Edit"},
                    {"toggle", if(row.enabled, do: "Pause", else: "Resume")},
                    {"history", "Recent dispatches"},
                    {"rotate", "Rotate credential"},
                    {"delete", "Delete"}
                  ]
                }
                class="ghost"
                phx-click={event}
                phx-value-id={row.id}
                phx-target={@myself}
                data-confirm={
                  if event in ["rotate", "delete"],
                    do: "Revoke this routine's current webhook credential?"
                }
              >{label}</button>
            </div>
            <div :if={@history && elem(@history, 0) == row.id}>
              <p :if={elem(@history, 1) == []}>No deliveries yet.</p>
              <p :for={dispatch <- elem(@history, 1)}>
                {Calendar.strftime(dispatch.inserted_at, "%b %d %H:%M UTC")} · {dispatch.request_id} · {dispatch.status}
                <.link
                  :if={dispatch.track_id}
                  patch={"/p/#{row.project_id}/t/#{dispatch.track_id}"}
                  style="text-decoration:underline"
                >Open track</.link>
              </p>
            </div>
          </article>
        </section>
      </div>
    </section>
    """
  end
end
