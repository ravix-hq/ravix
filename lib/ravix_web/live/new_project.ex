defmodule RavixWeb.Live.NewProject do
  @moduledoc """
  The workspace's New project form.

  The walkthrough's last step used to draw it too; it now asks for a first
  prompt instead (`RavixWeb.Live.QuickStart`), which creates the project
  through the same `Ravix.Projects.create/2`.

  Pages own creation and repository reads. This component renders the same fields
  in both places; its helpers preserve drafts while availability is refreshed.
  The credential panel is a sibling of the project form, never a nested form.
  """
  use RavixWeb, :html

  alias Ravix.Accounts.{Inference, User}
  alias RavixWeb.Live.{Async, Form}

  def init(socket, mode \\ "github") do
    socket
    |> assign(
      project_form: Form.new(:new_project),
      project_agents: nil,
      project_picker_tracked: false,
      project_agent_error: nil,
      project_mode: mode,
      project_generation: System.unique_integer([:positive])
    )
    |> refresh()
  end

  def refresh(socket) do
    user = socket.assigns.current_user
    Async.traced_async(socket, :project_agents, fn -> Inference.usable_agents(user) end)
  end

  def availability(socket, {:ok, agents}) do
    selected = socket.assigns.project_form[:runtime].value
    default = socket.assigns.current_user.agent
    chosen = if default in agents, do: default, else: List.first(agents)
    params = socket.assigns.project_form.params

    params =
      if selected in [nil, ""],
        do: Map.put(params, "runtime", chosen && to_string(chosen)),
        else: params

    socket = track_picker(socket, agents)

    assign(socket,
      project_agents: agents,
      project_agent_error: nil,
      project_form: Form.new(:new_project, params)
    )
  end

  def availability(socket, {:error, reason}),
    do:
      assign(socket,
        project_agents: nil,
        project_agent_error: RavixWeb.Error.from(reason).message
      )

  # Availability arrives once the picker is visible; retries and renders are
  # still the same opening. A new form generation resets this observation.
  defp track_picker(socket, agents) do
    if picker_visible?(socket) and not socket.assigns.project_picker_tracked and
         Enum.any?(User.agents(), &(&1 not in agents)) do
      Ravix.Analytics.track(socket.assigns.current_user, :agent_picker_shown_unconnected)
      assign(socket, project_picker_tracked: true)
    else
      socket
    end
  end

  defp picker_visible?(socket), do: socket.assigns.dialog == :new_project

  def edit(socket, params),
    do:
      assign(socket,
        project_form:
          Form.new(:new_project, Map.merge(socket.assigns.project_form.params, params))
      )

  def choose(socket, agent) when agent in ["claude", "codex"],
    do: edit(socket, %{"runtime" => agent})

  def choose(socket, _agent), do: socket

  def connected(socket, user, agent) do
    agents = Enum.uniq([agent | socket.assigns.project_agents || []])

    socket
    |> Phoenix.LiveView.cancel_async(:project_agents)
    |> assign(current_user: user, project_agents: agents, project_agent_error: nil)
    |> edit(%{})
  end

  def create(%{assigns: %{busy: true}} = socket, _params, _create), do: socket

  def create(socket, params, create) do
    socket = edit(socket, params)
    params = socket.assigns.project_form.params
    repo = Enum.find(socket.assigns.repos, &(&1.full_name == params["repo"]))
    user = socket.assigns.current_user
    attrs = Map.take(params, ["name", "runtime"])

    cond do
      repo ->
        attrs =
          Map.merge(attrs, %{"repo" => repo.full_name, "installation_id" => repo.installation_id})

        socket
        |> assign(busy: true)
        |> Async.traced_async(:create_project, fn -> create.(user, attrs) end)

      params["repo"] in [nil, ""] ->
        socket
        |> assign(busy: true)
        |> Async.traced_async(:create_project, fn -> create.(user, attrs) end)

      true ->
        {:ok, form} =
          Form.refuse(
            socket.assigns.project_form,
            {:unprocessable, "invalid_repository",
             "Choose a repository from the list, or leave it empty for scratch."}
          )

        assign(socket, project_form: form)
    end
  end

  def panel_id(runtime, generation), do: "project-connect-#{runtime}-#{generation}"

  def active_panel?(socket, id) do
    runtime = socket.assigns.project_form[:runtime].value

    id == panel_id(runtime, socket.assigns.project_generation) and runtime in ["claude", "codex"] and
      not usable?(socket.assigns.project_agents, runtime)
  end

  defp usable?(agents, runtime),
    do: is_list(agents) and Enum.any?(agents, &(to_string(&1) == runtime))

  defp repositories(repos, query) do
    query = String.downcase(query || "")

    repos
    |> Enum.filter(&String.contains?(String.downcase(&1.full_name), query))
    |> Enum.sort_by(&String.downcase(&1.full_name))
  end

  attr :submit_class, :string, default: "primary"
  attr :autofocus, :boolean, default: false
  attr :form_id, :string, required: true
  attr :project_form, :any, required: true
  attr :project_agents, :any, required: true
  attr :project_agent_error, :any, required: true
  attr :project_generation, :integer, required: true
  attr :project_mode, :string, required: true
  attr :current_user, :any, required: true
  attr :session_hash, :any, required: true
  attr :repos, :list, required: true
  attr :repos_loading, :boolean, default: false
  attr :installations, :any, required: true
  attr :installation, :any, required: true
  attr :busy, :boolean, required: true

  def render_form(assigns) do
    assigns = assign(assigns, runtime: assigns.project_form[:runtime].value)

    ~H"""
    <div
      class="new-project-fields"
      id="new-project-fields"
      phx-hook={@autofocus && "ProjectFormFocus"}
      data-focus={if @project_mode == "scratch", do: "#project-name", else: "#project-repo"}
    >
      <div
        class="field"
        id="project-runtime"
        role="group"
        aria-labelledby="project-agent-label"
        aria-describedby="project-agent-error"
      >
        <span id="project-agent-label" class="label">Agent</span>
        <div class="agent-choices">
          <button
            :for={{label, agent} <- RavixWeb.AgentName.options()}
            type="button"
            id={"project-agent-#{agent}"}
            class={["agent-choice", @runtime == agent && "on"]}
            aria-pressed={to_string(@runtime == agent)}
            phx-click="choose-project-agent"
            phx-value-agent={agent}
            disabled={@busy}
          >
            <strong>{label}</strong>
            <small>{cond do
              usable?(@project_agents, agent) -> "Connected"
              @project_agent_error -> "Connection status unavailable"
              is_nil(@project_agents) -> "Checking connection…"
              true -> "Not connected — connect to use"
            end}</small>
          </button>
        </div>
        <div id="project-agent-error" aria-live="polite">
          <p :for={{message, _} <- @project_form[:runtime].errors} class="error">{message}</p>
          <p :if={@project_agent_error} class="error">{@project_agent_error}</p>
        </div>
        <button
          :if={@project_agent_error}
          type="button"
          class="ghost"
          phx-click="refresh-project-agents"
        >Check connections again</button>
        <p :if={@runtime in ["claude", "codex"]} class="hint">
          Every turn in this project uses your {RavixWeb.AgentName.label(@runtime)} subscription or API key, whoever is working.
        </p>
      </div>
      <div
        :if={@runtime in ["claude", "codex"] and not usable?(@project_agents, @runtime)}
        id={"project-connect-#{@runtime}"}
      >
        <.live_component
          :if={@runtime in ["claude", "codex"] and not usable?(@project_agents, @runtime)}
          module={RavixWeb.Live.AgentPanel}
          id={panel_id(@runtime, @project_generation)}
          scoped_agent={if @runtime == "codex", do: :codex, else: :claude}
          current_user={@current_user}
          session_hash={@session_hash}
        />
      </div>
      <.loading_status :if={@repos_loading and @project_mode != "scratch"}>
        Loading GitHub repositories…
      </.loading_status>
      <form
        :if={@project_mode != "scratch" and @installations not in [nil, []]}
        id="installation-form"
        phx-change="installation"
      >
        <.input
          name="installation"
          id="installation"
          label="GitHub account"
          type="select"
          value={@installation}
          options={Enum.map(@installations, &{&1.account, &1.id})}
        />
      </form>
      <.form :let={f} for={@project_form} id={@form_id} phx-submit="create-project" phx-change="edit">
        <input type="hidden" name="new_project[runtime]" value={@runtime || ""} />
        <div :if={@project_mode != "scratch"}>
          <.input
            field={f[:repo]}
            id="project-repo"
            label="Repository"
            list="project-repositories"
            placeholder="Search repositories, or leave empty for scratch"
            autocomplete="off"
            aria-busy={to_string(@repos_loading)}
          />
          <datalist id="project-repositories">
            <option :for={repo <- repositories(@repos, f[:repo].value)} value={repo.full_name} />
          </datalist>
          <p><a href="/api/auth/install">Connect or manage GitHub repositories ↗</a></p>
        </div>
        <input :if={@project_mode == "scratch"} type="hidden" name="new_project[repo]" value="" />
        <.input
          field={f[:name]}
          id="project-name"
          label="Project name"
          maxlength="120"
          placeholder="Defaults to the repository's name"
        />
        <.loading_status :if={@busy}>Creating project and preparing its machine…</.loading_status>
        <button
          class={@submit_class}
          disabled={
            @busy or (@repos_loading and @project_mode != "scratch") or
              not usable?(@project_agents, @runtime)
          }
          phx-disable-with="Creating…"
        >
          {if @busy, do: "Creating project…", else: "Create project"}
        </button>
      </.form>
    </div>
    """
  end
end
