defmodule RavixWeb.Live.SchedulesPanel do
  @moduledoc "Create, edit and pause personal project routines."
  use RavixWeb, :live_component
  alias Ravix.Schedules
  alias Ravix.Schedules.Schedule

  @impl true
  def mount(socket), do: {:ok, assign(socket, editing: nil, form: blank_form(), error: nil)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, load(socket)}
  end

  @impl true
  def handle_event("save", %{"schedule" => attrs}, socket) do
    %{current_user: user, editing: editing} = socket.assigns

    result =
      if editing,
        do: Schedules.update(user, editing, attrs),
        else: Schedules.create(user, attrs["project_id"], attrs)

    case result do
      {:ok, _} ->
        {:noreply, socket |> assign(editing: nil, form: blank_form(), error: nil) |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs, as: :schedule), error: nil)}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           form: to_form(attrs, as: :schedule),
           error: RavixWeb.Error.from(reason).message
         )}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Schedules.get(socket.assigns.current_user, id) do
      {:ok, row} ->
        {:noreply,
         assign(socket,
           editing: id,
           form: to_form(Schedule.changeset(row, %{}), as: :schedule),
           error: nil
         )}

      {:error, reason} ->
        refuse(socket, reason)
    end
  end

  def handle_event("cancel", _, socket),
    do: {:noreply, assign(socket, editing: nil, form: blank_form(), error: nil)}

  def handle_event("toggle", %{"id" => id}, socket) do
    with {:ok, row} <- Schedules.get(socket.assigns.current_user, id),
         {:ok, _} <-
           Schedules.update(socket.assigns.current_user, id, %{enabled: not row.enabled}) do
      {:noreply, load(socket)}
    else
      {:error, reason} -> refuse(socket, reason)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Schedules.delete(socket.assigns.current_user, id) do
      {:ok, _} -> {:noreply, socket |> assign(editing: nil, form: blank_form()) |> load()}
      {:error, reason} -> refuse(socket, reason)
    end
  end

  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    rows = Schedules.list(socket.assigns.current_user)
    socket = assign(socket, schedules: rows)

    if socket.assigns.editing && not Enum.any?(rows, &(&1.id == socket.assigns.editing)),
      do: assign(socket, editing: nil, form: blank_form()),
      else: socket
  end

  defp refuse(socket, reason),
    do: {:noreply, socket |> assign(error: RavixWeb.Error.from(reason).message) |> load()}

  defp blank_form,
    do: to_form(%{"frequency" => "daily", "time" => "09:00", "weekday" => "1"}, as: :schedule)

  defp project_name(projects, id),
    do: Enum.find_value(projects, "Project", &if(&1.id == id, do: &1.display_name))

  defp timestamp(nil), do: "Never"
  defp timestamp(time), do: Calendar.strftime(time, "%b %d, %Y at %H:%M UTC")

  @impl true
  def render(assigns) do
    ~H"""
    <div id="schedules-panel" class="inbox schedules-page">
      <header>
        <div class="row">
          <h1>Schedules</h1><span class="spacer"></span>
          <button
            class="ghost"
            phx-click="refresh"
            phx-target={@myself}
            aria-describedby="schedules-refresh-note"
          >Refresh</button>
        </div>
        <p>Run a prompt on a schedule. Each run opens a fresh track in your project.</p>
        <p id="schedules-refresh-note" class="dim">
          Refresh to see the latest run status and changes made in another tab.
        </p>
      </header>
      <p :if={@error} role="alert" class="schedule-error">{@error}</p>
      <div class="schedules-layout">
        <section class="schedule-editor" aria-labelledby="schedule-form-title">
          <h2 id="schedule-form-title">{if @editing, do: "Edit schedule", else: "New schedule"}</h2>
          <.form for={@form} id="schedule-form" phx-submit="save" phx-target={@myself}>
            <.input
              field={@form[:name]}
              label="Name"
              required
              maxlength="100"
              placeholder="Weekly code review"
            />
            <.input
              field={@form[:project_id]}
              type="select"
              label="Project"
              required
              disabled={not is_nil(@editing)}
              prompt="Select a project"
              options={for p <- @projects, p.access != :tracks, do: {p.display_name, p.id}}
            />
            <.input
              field={@form[:prompt]}
              type="textarea"
              label="Prompt"
              required
              maxlength="100000"
              rows="6"
              placeholder="Review recent changes and suggest improvements…"
            />
            <.input
              field={@form[:frequency]}
              type="select"
              label="Repeat"
              options={[{"Every hour", :hourly}, {"Every day", :daily}, {"Every week", :weekly}]}
            />
            <.input field={@form[:time]} type="time" label="Time (UTC)" required />
            <.input
              field={@form[:weekday]}
              type="select"
              label="Day (weekly schedules)"
              options={[
                {"Monday", 1},
                {"Tuesday", 2},
                {"Wednesday", 3},
                {"Thursday", 4},
                {"Friday", 5},
                {"Saturday", 6},
                {"Sunday", 7}
              ]}
            />
            <p class="meta">
              Hourly schedules use the minute of the selected time. All times are UTC. Missed occurrences combine into one run when service resumes.
            </p>
            <div class="row">
              <button type="submit" class="primary" phx-disable-with="Saving…">{if @editing,
                do: "Save changes",
                else: "Create schedule"}</button>
              <button
                :if={@editing}
                type="button"
                class="ghost"
                phx-click="cancel"
                phx-target={@myself}
              >Cancel</button>
            </div>
          </.form>
        </section>
        <section class="schedule-list" aria-label="Your schedules">
          <div :if={@schedules == []} class="inbox-empty">
            <h2>No schedules yet</h2><p>Choose a project, write a prompt, and set when it runs.</p>
          </div>
          <article :for={schedule <- @schedules} id={"schedule-#{schedule.id}"} class="schedule-card">
            <div class="row">
              <h2>{schedule.name}</h2><span class="spacer"></span><span class="badge">{if schedule.enabled,
                do: "Active",
                else: "Paused"}</span>
            </div>
            <p class="meta">{project_name(@projects, schedule.project_id)} · {schedule.frequency}</p>
            <p class="schedule-prompt">{schedule.prompt}</p>
            <p :if={schedule.enabled}>Next: {timestamp(schedule.next_run_at)}</p>
            <p>Last dispatch: {timestamp(schedule.last_run_at)}</p>
            <p :if={schedule.last_status}>{schedule.last_status}</p>
            <.link
              :if={schedule.last_track_id}
              patch={"/p/#{schedule.project_id}/t/#{schedule.last_track_id}"}
            >Open latest run</.link>
            <div class="row schedule-controls">
              <button class="ghost" phx-click="edit" phx-value-id={schedule.id} phx-target={@myself}>Edit</button>
              <button class="ghost" phx-click="toggle" phx-value-id={schedule.id} phx-target={@myself}>{if schedule.enabled,
                do: "Pause",
                else: "Resume"}</button>
              <button
                class="ghost"
                phx-click="delete"
                phx-value-id={schedule.id}
                phx-target={@myself}
                data-confirm="Delete this schedule? Existing tracks will remain."
              >Delete</button>
            </div>
          </article>
        </section>
      </div>
    </div>
    """
  end
end
