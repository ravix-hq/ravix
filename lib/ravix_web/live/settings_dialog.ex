defmodule RavixWeb.Live.SettingsDialog do
  @moduledoc """
  Owner-only project settings, organized into independently saved sections.

  This component owns forms and asynchronous writes. WorkspaceLive retains
  navigation, flashes and refreshing the project rail. Keeping the dialog
  preserves every workspace entry point and the selected track. SettingsSections
  owns only browser navigation and unsaved-input warnings, never secret values.
  """
  use RavixWeb, :live_component

  alias Ravix.Accounts.{Access, Inference}
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Previews
  alias Ravix.Projects
  alias Ravix.Projects.Machine.Rebuild
  alias Ravix.Tracks
  alias RavixWeb.Live.Form
  alias RavixWeb.Live.Hooks
  alias RavixWeb.Live.Params
  alias RavixWeb.ModelName

  @packages ~w(apt pip npm)

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         settings: nil,
         agents: nil,
         agent_error: nil,
         agent_generation: System.unique_integer([:positive]),
         pending: MapSet.new(),
         save_state: "",
         save_version: 0,
         switching_agent: false,
         switch_confirmation: nil,
         confirmations: %{}
       )}

  @impl true
  def update(%{agent_tick: {id, tick}}, socket) do
    if active_panel?(socket, id) and
         match?({:ok, _}, Access.project_of(user(socket), project_id(socket))) do
      send_update(RavixWeb.Live.AgentPanel, id: id, tick: tick)
    end

    {:ok, socket}
  end

  def update(%{connected_agent: agent}, socket) do
    {:ok,
     socket
     |> cancel_async(:settings_agents)
     |> assign(agents: Enum.uniq([agent | socket.assigns.agents || []]), agent_error: nil)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok, if(socket.assigns[:settings], do: socket, else: load(socket))}
  end

  @impl true
  def handle_event(event, params, socket) do
    case Access.project_of(user(socket), project_id(socket)) do
      {:ok, _} -> settings_event(event, params, socket)
      {:error, reason} -> {:noreply, error(socket, reason)}
    end
  end

  defp settings_event("choose-settings-agent", %{"agent" => agent}, socket)
       when agent in ["claude", "codex"] do
    if socket.assigns.switch_confirmation || MapSet.size(socket.assigns.pending) > 0 ||
         socket.assigns.settings_form[:runtime].value == agent do
      {:noreply, socket}
    else
      model = List.first(Catalog.models_for(socket.assigns.settings.catalog, agent)) || ""
      {:noreply, edit_agent(socket, %{"runtime" => agent, "model" => model})}
    end
  end

  defp settings_event("choose-settings-agent", _, socket), do: {:noreply, socket}

  defp settings_event("edit-agent", %{"settings" => params}, socket),
    do: {:noreply, edit_agent(socket, Map.take(params, ~w(model instructions)))}

  defp settings_event("discard-agent", _, socket),
    do: {:noreply, assign(socket, settings_form: settings_form(socket.assigns.settings))}

  defp settings_event("refresh-settings-agents", _, socket),
    do: {:noreply, refresh_agents(socket)}

  defp settings_event("save-settings", %{"settings" => params}, socket) do
    attrs =
      params
      |> Map.take(~w(name runtime model instructions setup_script))
      |> put_packages(params)

    switching =
      is_binary(attrs["runtime"]) and attrs["runtime"] != socket.assigns.settings.runtime

    socket =
      assign(socket,
        switching_agent: switching,
        switch_confirmation: nil,
        settings_form: Form.new(:settings, Map.merge(socket.assigns.settings_form.params, params))
      )

    if switching do
      user = user(socket)
      id = project_id(socket)

      {:noreply,
       begin(socket, :switch_preview, fn ->
         with {:ok, tracks} <- Tracks.list(user, id) do
           {:ok, %{attrs: attrs, count: length(tracks)}}
         end
       end)}
    else
      {:noreply, save_settings(socket, attrs)}
    end
  end

  defp settings_event("confirm-agent-switch", _, socket) do
    case socket.assigns.switch_confirmation do
      %{attrs: attrs} ->
        {:noreply,
         socket
         |> assign(switch_confirmation: nil)
         |> save_settings(Map.put(attrs, "rebuild", true))}

      nil ->
        {:noreply, socket}
    end
  end

  defp settings_event("cancel-agent-switch", _, socket),
    do: {:noreply, assign(socket, switch_confirmation: nil)}

  defp settings_event("save-secret", %{"secret" => params}, socket) do
    # The store and the key go back into the form so a refusal can be
    # corrected. The value does not: a secret in an assign is a secret in the
    # page's state and in its next diff, which is the one thing this form
    # must not do, and `<.input type="password">` would render it straight
    # back into the box. It goes to Fountain inside the task and nowhere else.
    kept = Map.drop(params, ["value"])
    secret = Map.take(params, ~w(store key value))
    user = user(socket)
    id = project_id(socket)

    {:noreply,
     socket
     |> assign(secret_form: Form.new(:secret, kept))
     |> begin(:secret, fn -> Projects.update_settings(user, id, %{secret: secret}) end)}
  end

  defp settings_event(
         "confirm-secret-change",
         %{"confirmed" => "true", "generation" => generation},
         socket
       )
       when is_binary(generation) do
    case Integer.parse(generation) do
      {generation, ""} ->
        user = user(socket)
        id = project_id(socket)

        {:noreply,
         begin(socket, :secret_confirmation, fn ->
           Projects.confirm_secret_change(user, id, generation)
         end)}

      _ ->
        {:noreply, flash(socket, :error, "Reopen Settings to confirm the latest secret change.")}
    end
  end

  defp settings_event("confirm-secret-change", _, socket),
    do:
      {:noreply,
       flash(socket, :error, "Confirm that the previous secret change has finished first.")}

  defp settings_event("save-preview-defaults", params, socket) do
    fields = Map.get(params, "preview_defaults", %{})
    config = if Params.flag(params, "clear"), do: nil, else: fields

    {:noreply,
     result(
       assign(socket, save_state: "error", defaults_form: Form.new(:preview_defaults, fields)),
       Previews.set_defaults(user(socket), project_id(socket), config),
       fn s, defaults ->
         s |> show_defaults(defaults) |> saved() |> flash(:info, "Preview defaults saved.")
       end,
       :defaults_form
     )}
  end

  defp settings_event("confirm-danger", %{"action" => action, "confirm" => name}, socket)
       when action in ["rebuild", "delete"] do
    {:noreply, update(socket, :confirmations, &Map.put(&1, action, name))}
  end

  # The typed confirmation is the gate; which of the two irreversible things
  # happens after it is decided by the clause, not by a string compared again
  # further down.
  defp settings_event("project-danger", %{"action" => "rebuild", "confirm" => name}, socket),
    do: {:noreply, danger(socket, name, &Projects.rebuild/2)}

  defp settings_event("project-danger", %{"action" => "delete", "confirm" => name}, socket),
    do: {:noreply, danger(socket, name, &Projects.destroy/2)}

  @impl true
  def handle_async(name, response, socket) do
    Hooks.component(socket, fn ->
      if name == :danger or
           match?({:ok, _}, Access.project_of(user(socket), project_id(socket))) do
        async_result(name, response, socket)
      else
        {:noreply, redirect(socket, to: "/")}
      end
    end)
  end

  defp async_result(:settings_agents, {:ok, {:ok, agents}}, socket),
    do: {:noreply, assign(socket, agents: agents, agent_error: nil)}

  defp async_result(:settings_agents, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, agents: nil, agent_error: RavixWeb.Error.from(reason).message)}

  defp async_result(:settings, {:ok, response}, socket) do
    {:noreply,
     result(
       settle(socket, :settings),
       response,
       fn s, _ ->
         # The name may have changed, so the rail is wrong until the page
         # re-reads it. Saying so is this dialog's part; what to re-read is
         # the page's.
         if s.assigns.switching_agent do
           send(self(), :project_left_behind)
         else
           send(self(), :project_settings_saved)
         end

         s
         |> load()
         |> saved()
         |> flash(
           :info,
           "Settings saved."
         )
       end,
       :settings_form
     )}
  end

  defp async_result(:switch_preview, {:ok, response}, socket) do
    {:noreply,
     result(settle(socket, :switch_preview), response, fn s, confirmation ->
       assign(s, switch_confirmation: confirmation, save_state: "")
     end)}
  end

  defp async_result(:secret, {:ok, response}, socket) do
    {:noreply,
     result(
       socket |> settle(:secret) |> refresh_secret_confirmation(),
       response,
       fn s, _ -> s |> load() |> saved() |> flash(:info, "Secret updated.") end,
       :secret_form
     )}
  end

  defp async_result(:secret_confirmation, {:ok, response}, socket) do
    {:noreply,
     result(settle(socket, :secret_confirmation), response, fn s, _ ->
       s
       |> load()
       |> saved()
       |> flash(
         :info,
         "Secret changes are unlocked. Save the intended value again if needed, then rebuild dedicated tracks to apply it."
       )
     end)}
  end

  defp async_result(:danger, {:ok, response}, socket) do
    {:noreply,
     result(settle(socket, :danger), response, fn s, outcome ->
       # Both of these take you off the project: a rebuild closes every track
       # on it and a delete removes it outright.
       send(self(), :project_left_behind)
       report(s, outcome)
     end)}
  end

  defp async_result(name, {:exit, reason}, socket),
    do: {:noreply, socket |> settle(name) |> exit(reason)}

  # ── what is out ───────────────────────────────────────────────────────

  defp save_settings(socket, attrs) do
    user = user(socket)
    id = project_id(socket)
    begin(socket, :settings, fn -> Projects.update_settings(user, id, attrs) end)
  end

  # One of the dialog's three writes, started off this process and named in
  # `pending` until its answer or its exit settles it.
  defp begin(socket, name, call) do
    if MapSet.size(socket.assigns.pending) > 0 do
      socket
    else
      socket
      |> assign(save_state: "saving")
      |> update(:pending, &MapSet.put(&1, name))
      |> traced_async(name, call)
    end
  end

  defp settle(socket, name),
    do: socket |> assign(save_state: "error") |> update(:pending, &MapSet.delete(&1, name))

  defp saved(socket),
    do: socket |> assign(save_state: "saved") |> update(:save_version, &(&1 + 1))

  # ── loading ───────────────────────────────────────────────────────────

  defp refresh_secret_confirmation(socket) do
    case Access.project_of(user(socket), project_id(socket)) do
      {:ok, project} ->
        update(socket, :settings, fn settings ->
          Map.merge(settings, %{
            secrets_pending: project.secrets_pending,
            secrets_generation: project.secrets_generation
          })
        end)

      _ ->
        socket
    end
  end

  defp load(socket) do
    result(socket, Projects.settings(user(socket), project_id(socket)), fn s, settings ->
      defaults =
        case Previews.defaults(user(s), project_id(s)) do
          {:ok, value} -> value
          _ -> nil
        end

      s
      |> assign(settings: settings, settings_form: settings_form(settings))
      |> show_defaults(defaults)
      |> refresh_agents()
      # The secret form is always blank: values are write-only, so there is
      # nothing to read back, and a key left in the box from the last save
      # invites somebody to overwrite a secret they meant to add beside.
      |> assign(secret_form: Form.new(:secret, %{"store" => "env"}))
    end)
  end

  defp edit_agent(socket, params) do
    assign(socket,
      settings_form: Form.new(:settings, Map.merge(socket.assigns.settings_form.params, params)),
      save_state: ""
    )
  end

  defp refresh_agents(socket) do
    user = user(socket)
    traced_async(socket, :settings_agents, fn -> Inference.usable_agents(user) end)
  end

  defp usable?(agents, runtime),
    do: is_list(agents) and Enum.any?(agents, &(to_string(&1) == runtime))

  defp panel_id(socket),
    do:
      "settings-connect-#{socket.assigns.settings_form[:runtime].value}-#{socket.assigns.agent_generation}"

  defp active_panel?(socket, id),
    do:
      socket.assigns.settings != nil and id == panel_id(socket) and
        socket.assigns.settings_form[:runtime].value in ["claude", "codex"] and
        not usable?(socket.assigns.agents, socket.assigns.settings_form[:runtime].value)

  # The settings form opens on what is saved. The three package boxes are one
  # space-separated line each; `Ravix.Projects.Settings` holds them as a map
  # keyed by manager, and this is where the two spellings meet.
  defp settings_form(settings) do
    packages = Map.new(@packages, &{&1, Enum.join(settings.packages[&1] || [], " ")})

    Form.new(
      :settings,
      Map.merge(packages, %{
        "name" => settings.name,
        "runtime" => settings.runtime,
        "model" => settings.model,
        "instructions" => settings.instructions,
        "setup_script" => settings.setup_script
      })
    )
  end

  defp put_packages(attrs, params) do
    if Enum.any?(@packages, &Map.has_key?(params, &1)),
      do: Map.put(attrs, "packages", packages_from(params)),
      else: attrs
  end

  defp packages_from(params) do
    Map.new(@packages, fn key ->
      {key, String.split(params[key] || "", ~r/[\s,]+/, trim: true)}
    end)
  end

  # The defaults form shows what is saved, so it is rebuilt from the answer
  # rather than left holding what was typed --- which is also what clears a
  # refusal once the save goes through.
  defp show_defaults(socket, defaults) do
    config = defaults || %{}

    assign(socket,
      preview_defaults: defaults,
      defaults_form:
        Form.new(:preview_defaults, %{
          "directory" => Map.get(config, :directory, "."),
          "command" => Map.get(config, :command, ""),
          "readiness_path" => Map.get(config, :readiness_path, "/")
        })
    )
  end

  defp danger(socket, confirmation, call) do
    if confirmation == socket.assigns.project.name do
      user = user(socket)
      id = project_id(socket)
      begin(socket, :danger, fn -> call.(user, id) end)
    else
      flash(socket, :error, "Type the project name to confirm.")
    end
  end

  # What `Projects.rebuild/2` could not remove, which this is the only place
  # anybody hears about. Terminating the live conversations is best-effort by
  # design --- retiring the agent is the removal that has to work, and it did,
  # or there would be no `{:ok, _}` here --- so this is a report and not a
  # refusal. The value used to be discarded along with the rest of the
  # response, which made `failed` a list nothing in the app could observe.
  #
  # `destroy/2` answers `:ok` and arrives here as nil.
  defp report(socket, %Rebuild{failed: [_ | _] = failed}) do
    reasons =
      failed
      |> Enum.map(&String.trim_trailing(&1.why, "."))
      |> Enum.uniq()
      |> Enum.join("; ")

    noun = if length(failed) == 1, do: "track", else: "tracks"

    flash(
      socket,
      :error,
      "The machine was rebuilt. #{length(failed)} #{noun} would not stop first: #{reasons}."
    )
  end

  defp report(socket, _outcome), do: socket

  defp user(socket), do: socket.assigns.current_user
  defp project_id(socket), do: socket.assigns.project.id

  defp sections,
    do: [
      {"general", "General"},
      {"agent", "Agent"},
      {"environment", "Environment"},
      {"secrets", "Secrets"},
      {"previews", "Previews"},
      {"danger", "Danger zone"}
    ]

  defp model_options(values, current) do
    Enum.map(Enum.uniq(values ++ List.wrap(current)), &{ModelName.friendly(&1), &1})
  end

  defp model_labels(catalog, current) do
    catalog.models
    |> Map.values()
    |> List.flatten()
    |> Kernel.++(List.wrap(current))
    |> Map.new(&{&1, ModelName.friendly(&1)})
  end

  # ── the dialog ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :runtime, assigns[:settings_form] && assigns.settings_form[:runtime].value)

    ~H"""
    <div>
      <.dialog
        :if={@settings}
        id="settings-dialog"
        title="Project settings"
        on_close="dismiss"
        wide
      >
        <div
          id="settings-sections"
          data-component={@myself}
          phx-hook="SettingsSections"
          data-save-state={@save_state}
          data-save-version={@save_version}
          data-models={Jason.encode!(@settings.catalog.models)}
          data-model-labels={Jason.encode!(model_labels(@settings.catalog, @settings.model))}
          data-saved-model={@settings.model}
          data-saved-runtime={@settings.runtime}
        >
          <nav class="settings-nav" aria-label="Settings sections">
            <button
              :for={{key, title} <- sections()}
              type="button"
              class="ghost"
              data-settings-section={key}
              aria-controls={"settings-section-#{key}"}
              aria-current={if key == "general", do: "true", else: "false"}
            >{title}</button>
          </nav>
          <div class="settings-content">
            <p class="settings-feedback" role="status" aria-live="polite" data-settings-feedback>
              {case @save_state do
                "saving" ->
                  "Saving…"

                "saved" ->
                  "Saved."

                "error" ->
                  "Could not save. Review the errors and try again. Earlier changes in this save may have succeeded."

                _ ->
                  "Each section saves separately."
              end}
            </p>
            <button type="button" class="ghost settings-discard" data-settings-discard hidden>
              Discard changes
            </button>
            <section
              id="settings-section-general"
              data-settings-panel="general"
              aria-labelledby="settings-general-title"
            >
              <h3 id="settings-general-title" tabindex="-1">General</h3>
              <p class="settings-help">The name shown in your workspace.</p>
              <.form
                :let={f}
                for={@settings_form}
                id="settings-form"
                phx-target={@myself}
                phx-submit="save-settings"
              >
                <.input
                  field={f[:name]}
                  id="settings-name"
                  label="Name"
                  required
                  aria-describedby="settings-name-help"
                />
                <p id="settings-name-help" class="settings-help">
                  For example, “Customer portal”. The new name appears after you save; it does not change the repository or open tracks.
                </p>
                <button class="primary" phx-disable-with="Saving…" disabled={:settings in @pending}>Save general</button>
              </.form>
            </section>
            <section
              id="settings-section-agent"
              data-settings-panel="agent"
              aria-labelledby="settings-agent-title"
              hidden
            >
              <h3 id="settings-agent-title" tabindex="-1">Agent</h3>
              <p class="settings-help">
                Switching agents rebuilds the machine, closes every track and loses unpushed work on its disk. Model and instruction changes apply to new tracks.
              </p>
              <div class="field" role="group" aria-label="Agent">
                <div class="agent-choices">
                  <button
                    :for={{label, agent} <- RavixWeb.AgentName.options()}
                    type="button"
                    id={"settings-agent-#{agent}"}
                    class={["agent-choice", @runtime == agent && "on"]}
                    aria-pressed={to_string(@runtime == agent)}
                    phx-click="choose-settings-agent"
                    phx-target={@myself}
                    phx-value-agent={agent}
                    data-settings-agent={agent}
                    disabled={@switch_confirmation != nil or MapSet.size(@pending) > 0}
                  >
                    <strong>{label}</strong>
                    <small>{cond do
                      usable?(@agents, agent) -> "Connected"
                      @agent_error -> "Connection status unavailable"
                      is_nil(@agents) -> "Checking connection…"
                      true -> "Not connected — connect to use"
                    end}</small>
                  </button>
                </div>
                <p class="settings-help">
                  Every turn in this project uses your {RavixWeb.AgentName.label(@runtime)} subscription or API key, whoever is working.
                </p>
                <p :if={@agent_error} class="error">{@agent_error}</p>
                <button
                  :if={@agent_error}
                  type="button"
                  class="ghost"
                  phx-click="refresh-settings-agents"
                  phx-target={@myself}
                >Check connections again</button>
              </div>
              <div
                :if={@runtime in ["claude", "codex"] and not usable?(@agents, @runtime)}
                id={"settings-connect-#{@runtime}"}
              >
                <.live_component
                  module={RavixWeb.Live.AgentPanel}
                  id={"settings-connect-#{@runtime}-#{@agent_generation}"}
                  scoped_agent={if @runtime == "codex", do: :codex, else: :claude}
                  current_user={@current_user}
                  session_hash={@session_hash}
                />
              </div>
              <.form
                :let={f}
                for={@settings_form}
                id="agent-settings-form"
                phx-change="edit-agent"
                phx-target={@myself}
                phx-submit="save-settings"
              >
                <div class="field">
                  <input
                    type="hidden"
                    name="settings[runtime]"
                    id="settings-runtime"
                    value={@runtime}
                  />
                  <p :for={{message, _} <- f[:runtime].errors} class="error">{message}</p>
                  <p :if={@runtime not in ["claude", "codex"]} class="settings-help">
                    Current agent: {RavixWeb.AgentName.label(@runtime)}. Choose Claude Code or Codex to switch.
                  </p>
                </div>
                <.input
                  field={f[:model]}
                  id="settings-model"
                  disabled={
                    @switch_confirmation != nil or (@switching_agent and MapSet.size(@pending) > 0)
                  }
                  label="Model"
                  type="select"
                  options={
                    model_options(
                      Catalog.models_for(@settings.catalog, f[:runtime].value),
                      f[:model].value
                    )
                  }
                  aria-describedby="settings-model-help"
                />
                <p id="settings-model-help" class="settings-help">
                  Models available to this agent. Your saved choice is kept if the catalog is unavailable.
                </p>
                <.input
                  type="textarea"
                  field={f[:instructions]}
                  id="settings-instructions"
                  disabled={
                    @switch_confirmation != nil or (@switching_agent and MapSet.size(@pending) > 0)
                  }
                  label="Instructions"
                  rows="7"
                  aria-describedby="settings-instructions-help"
                />
                <p id="settings-instructions-help" class="settings-help">
                  Guidance added to every new track, such as “Run tests before committing.”
                </p>
                <button
                  data-save-agent
                  class="primary"
                  phx-disable-with="Saving…"
                  disabled={:settings in @pending}
                >Save agent</button>
                <button
                  data-switch-agent
                  class="primary"
                  phx-disable-with="Checking tracks…"
                  disabled={
                    MapSet.size(@pending) > 0 or @switch_confirmation != nil or
                      not usable?(@agents, @runtime)
                  }
                  hidden
                >
                  Switch and rebuild
                </button>
              </.form>
              <div
                :if={@switch_confirmation}
                id="agent-switch-confirmation"
                role="group"
                aria-label="Confirm agent switch"
              >
                <p>
                  This closes {@switch_confirmation.count} open {if @switch_confirmation.count == 1,
                    do: "track",
                    else: "tracks"} and discards the machine's disk, including unpushed work.
                </p>
                <button
                  id="confirm-agent-switch"
                  class="primary"
                  phx-click="confirm-agent-switch"
                  phx-target={@myself}
                  phx-mounted={Phoenix.LiveView.JS.focus()}
                  disabled={MapSet.size(@pending) > 0}
                >
                  Rebuild and switch
                </button>
                <button type="button" phx-click="cancel-agent-switch" phx-target={@myself}>
                  Cancel
                </button>
              </div>
            </section>
            <section
              id="settings-section-environment"
              data-settings-panel="environment"
              aria-labelledby="settings-environment-title"
              hidden
            >
              <h3 id="settings-environment-title" tabindex="-1">Environment</h3>
              <p class="settings-help">
                Applied when the machine is built. Applying changes to an existing machine requires a rebuild, which discards its disk and closes every track.
              </p>
              <.form
                :let={f}
                for={@settings_form}
                id="environment-settings-form"
                phx-target={@myself}
                phx-submit="save-settings"
              >
                <.input
                  type="textarea"
                  field={f[:setup_script]}
                  id="settings-setup"
                  label="Setup script"
                  class="mono"
                  rows="7"
                  aria-describedby="settings-setup-help"
                />
                <p id="settings-setup-help" class="settings-help">
                  Commands to prepare the project, such as <code>npm ci</code>. Keep credentials in Secrets.
                </p>
                <.input
                  :for={kind <- ~w(apt pip npm)}
                  field={f[String.to_existing_atom(kind)]}
                  id={"packages-#{kind}"}
                  label={"#{kind} packages"}
                  aria-describedby="settings-packages-help"
                />
                <p id="settings-packages-help" class="settings-help">
                  Separate names with spaces or commas. Leave blank to remove that package list.
                </p>
                <button class="primary" phx-disable-with="Saving…" disabled={:settings in @pending}>Save environment</button>
              </.form>
            </section>
            <section
              id="settings-section-secrets"
              data-settings-panel="secrets"
              aria-labelledby="settings-secrets-title"
              hidden
            >
              <h3 id="settings-secrets-title" tabindex="-1">Secrets</h3>
              <p class="settings-help">
                Values are never shown again. Changes apply to new tracks.
              </p>
              <p class="settings-help">
                Environment secrets become machine environment variables. Vault secrets are inserted into outgoing requests and stay off the machine. The same key can exist in both.
              </p>
              <p class="settings-help">
                Use an existing key to replace it. Submit an empty value to remove it.
              </p>
              <.form
                :if={Map.get(@settings, :secrets_pending, false)}
                for={%{}}
                id="secret-confirmation-form"
                phx-target={@myself}
                phx-submit="confirm-secret-change"
              >
                <p role="status">
                  The previous secret change could not be confirmed. Check in Fountain that it has
                  finished before unlocking more changes. Values cannot be checked here. Save the
                  intended value again if needed, then rebuild dedicated tracks to apply it.
                </p>
                <input type="hidden" name="generation" value={@settings.secrets_generation} />
                <label>
                  <input type="checkbox" name="confirmed" value="true" required />
                  I confirmed the previous secret change has finished in Fountain.
                </label>
                <button type="submit" class="primary" disabled={:secret_confirmation in @pending}>
                  Confirm and unlock secret changes
                </button>
              </.form>
              <div
                :for={
                  {store, label, keys} <- [
                    {"env", "Environment", @settings.env_keys},
                    {"vault", "Vault", @settings.vault_keys}
                  ]
                }
                class="settings-secret-list"
              >
                <h4>{label} keys</h4>
                <p :if={keys == []} class="settings-help">No keys in this store.</p>
                <ul :if={keys != []}>
                  <li :for={key <- keys}>
                    <code>{key}</code>
                    <button
                      type="button"
                      class="ghost"
                      data-secret-key={key}
                      data-secret-store={store}
                      data-secret-action="replace"
                      aria-label={"Replace #{label} secret #{key}"}
                    >Replace</button>
                    <button
                      type="button"
                      class="ghost"
                      data-secret-key={key}
                      data-secret-store={store}
                      data-secret-action="remove"
                      aria-label={"Remove #{label} secret #{key}"}
                    >Remove</button>
                  </li>
                </ul>
              </div>
              <.form
                :let={f}
                for={@secret_form}
                id="secret-form"
                phx-target={@myself}
                phx-submit="save-secret"
              >
                <.input
                  field={f[:store]}
                  id="secret-store"
                  label="Store"
                  type="select"
                  options={[{"Environment", "env"}, {"Vault", "vault"}]}
                />
                <.input field={f[:key]} id="secret-key" label="Key" required />
                <.input
                  field={f[:value]}
                  id="secret-value"
                  type="password"
                  label="Value"
                  autocomplete="new-password"
                />
                <button class="primary" phx-disable-with="Saving…" disabled={:secret in @pending}>
                  Update secret
                </button>
              </.form>
            </section>
            <section
              id="settings-section-previews"
              data-settings-panel="previews"
              aria-labelledby="settings-previews-title"
              hidden
            >
              <h3 id="settings-previews-title" tabindex="-1">Previews</h3>
              <p class="settings-help">
                Defaults for tracks without a preview override. Saving does not restart running previews.
              </p>
              <.form
                :let={f}
                for={@defaults_form}
                id="preview-defaults-form"
                phx-target={@myself}
                phx-submit="save-preview-defaults"
              >
                <.input
                  field={f[:directory]}
                  id="default-directory"
                  label="App directory"
                  aria-describedby="default-directory-help"
                />
                <p id="default-directory-help" class="settings-help">
                  Relative path, such as apps/web. Use . for the repository root.
                </p>
                <.input
                  field={f[:command]}
                  id="default-command"
                  label="Command (must honor $PORT)"
                  aria-describedby="default-command-help"
                />
                <p id="default-command-help" class="settings-help">
                  Start the app on the assigned port and fail if it is occupied. For example: <code>npm run dev -- --host 0.0.0.0 --port "$PORT" --strictPort</code>.
                </p>
                <.input
                  field={f[:readiness_path]}
                  id="default-readiness"
                  label="Readiness path"
                  aria-describedby="default-readiness-help"
                />
                <p id="default-readiness-help" class="settings-help">
                  An HTTP path that responds when the app is ready, for example /health or /.
                </p>
                <button class="primary" phx-disable-with="Saving…">Save defaults</button><button
                  name="clear"
                  value="true"
                  class="ghost"
                >Clear defaults</button>
              </.form>
            </section>
            <section
              id="settings-section-danger"
              class="settings-danger"
              data-settings-panel="danger"
              aria-labelledby="settings-danger-title"
              hidden
            >
              <h3 id="settings-danger-title" tabindex="-1">Danger zone</h3>
              <p>
                Rebuilding discards the machine’s disk and closes every track, keeping project settings and secrets for the next machine. Unpushed work on that disk is lost. Deleting also removes the project settings and secrets. These actions cannot be undone.
              </p>
              <form
                :for={
                  {action, label} <- [{"rebuild", "Rebuild machine"}, {"delete", "Delete project"}]
                }
                id={"project-#{action}-form"}
                phx-target={@myself}
                phx-change="confirm-danger"
                phx-submit="project-danger"
              >
                <h4>{label}</h4>
                <input type="hidden" name="action" value={action} />
                <.input
                  name="confirm"
                  id={"#{action}-confirm"}
                  label={"Type #{@project.name} to confirm #{if action == "rebuild", do: "rebuilding", else: "deletion"}"}
                  value={Map.get(@confirmations, action, "")}
                  autocomplete="off"
                  required
                />
                <button
                  name="action"
                  value={action}
                  class={if action == "delete", do: "danger", else: "ghost"}
                  disabled={
                    Map.get(@confirmations, action) != @project.name or MapSet.size(@pending) > 0
                  }
                  phx-disable-with="Working…"
                >
                  {label}
                </button>
              </form>
            </section>
          </div>
        </div>
      </.dialog>
    </div>
    """
  end
end
