defmodule RavixWeb.Live.ConductorSetupImport do
  @moduledoc "Explicit repository setup discovery and selection on the Machine settings page."
  use RavixWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Ravix.Accounts.Access
  alias Ravix.Projects.ConductorSetup
  alias Ravix.Projects.ConductorSetup.Parser
  alias RavixWeb.Live.Hooks

  @impl true
  def mount(socket), do: {:ok, assign(socket, report: nil, loading: false, error: nil)}

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("discover", _, socket) do
    user = socket.assigns.current_user
    id = socket.assigns.project.id

    case Access.project_of(user, id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(loading: true, report: nil, error: nil)
         |> start_async(:discover, fn -> ConductorSetup.discover(user, id) end)}

      {:error, reason} ->
        {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event("apply", %{"import" => params}, socket) do
    with {:ok, project} <-
           Access.project_of(socket.assigns.current_user, socket.assigns.project.id),
         :ok <- current_report(socket.assigns.report, project),
         {:ok, selection} <- Parser.select(socket.assigns.report, params) do
      send_update(RavixWeb.Live.ProjectSettings,
        id: socket.assigns.settings_id,
        conductor_selection: selection,
        conductor_repository: {project.repo_full_name, project.default_branch || "main"}
      )

      {:noreply, assign(socket, error: nil)}
    else
      {:error, reason} -> {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event("apply", _, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:discover, response, socket) do
    Hooks.component(socket, fn ->
      with {:ok, project} <-
             Access.project_of(socket.assigns.current_user, socket.assigns.project.id),
           {:ok, {:ok, report}} <- response,
           :ok <- current_report(report, project) do
        {:noreply, assign(socket, loading: false, report: report, error: nil)}
      else
        {:error, reason} ->
          {:noreply, refuse(socket, reason)}

        {:ok, {:error, reason}} ->
          {:noreply, refuse(socket, reason)}

        {:exit, _} ->
          {:noreply, refuse(socket, {:unavailable, "Repository discovery failed. Try again."})}
      end
    end)
  end

  defp current_report(nil, _),
    do: {:error, {:conflict, "conductor_setup", "Discover repository setup first."}}

  defp current_report(report, project) do
    if {report.repository, report.branch} ==
         {project.repo_full_name, project.default_branch || "main"},
       do: :ok,
       else:
         {:error, {:conflict, "conductor_setup", "Repository changed. Discover its setup again."}}
  end

  defp refuse(socket, reason),
    do: assign(socket, loading: false, error: RavixWeb.Error.from(reason).message)

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="settings-part" data-unsaved-ignore>
      <h2>Import Conductor setup</h2>
      <p class="settings-help">
        Inspect shared repository settings on the default branch. Review commands before applying;
        discovery runs nothing. Your current and entered settings stay until you select a replacement.
      </p>
      <button
        type="button"
        id="discover-conductor-setup"
        class="ghost"
        phx-click="discover"
        phx-target={@myself}
        disabled={@loading}
      >
        {if @loading, do: "Inspecting repository…", else: "Discover repository setup"}
      </button>
      <p :if={@error} role="alert">{@error}</p>
      <div :if={@report}>
        <p class="settings-help">{@report.repository} · {@report.branch}</p>
        <p :if={@report.sources == []}>No shared Conductor setup files found.</p>
        <p :for={source <- @report.sources}><code>{source}</code></p>
        <p :for={warning <- @report.warnings} class="settings-help">{warning}</p>
        <form
          id="conductor-import-form"
          phx-submit={
            JS.push("apply", target: @myself)
            |> JS.dispatch("unsaved:dirty", to: "#project-machine")
          }
        >
          <fieldset :if={@report.setup}>
            <legend>Setup candidate</legend>
            <pre style="white-space: pre-wrap; overflow-wrap: anywhere;"><code>{@report.setup.command}</code></pre>
            <p :for={issue <- @report.setup.issues} class="settings-help">{issue}</p>
            <label>
              <input
                type="checkbox"
                name="import[setup]"
                value="true"
                disabled={not @report.setup.selectable?}
              /> Replace the setup script
            </label>
          </fieldset>
          <fieldset :if={@report.runs != []}>
            <legend>Run candidates</legend>
            <label><input type="radio" name="import[run]" value="" checked />
            Keep the current run script</label>
            <div :for={run <- @report.runs}>
              <label>
                <input type="radio" name="import[run]" value={run.id} disabled={not run.selectable?} />
                {run.id}{if run.default?, do: " · Conductor default"}
              </label>
              <pre style="white-space: pre-wrap; overflow-wrap: anywhere;"><code>{run.command}</code></pre>
              <p class="settings-help">Directory: <code>{run.directory}</code></p>
              <p :for={issue <- run.issues} class="settings-help">{issue}</p>
            </div>
          </fieldset>
          <p class="settings-help">
            Run servers must honor <code>$PORT</code>, bind to <code>127.0.0.1</code> and refuse
            port fallback. Applying fills the selected settings fields; review and Save to persist them.
            Setup runs when a machine is built. Applying does not start a run script.
          </p>
          <button :if={@report.setup || @report.runs != []} type="submit" class="primary">
            Apply selected scripts to settings
          </button>
        </form>
        <h3>Cloud provisioning suggestions</h3>
        <p class="settings-help">
          Patterns from {@report.pattern_source}. Provision required configuration and secrets explicitly.
          Ravix does not read your Mac, copy matching files or import environment values.
        </p>
        <ul>
          <li :for={pattern <- @report.patterns}><code>{pattern}</code></li>
        </ul>
      </div>
    </section>
    """
  end
end
