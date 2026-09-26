defmodule RavixWeb.Live.SettingsDialog do
  @moduledoc """
  Owner-only project settings, organized into independently saved sections.

  This component owns forms and asynchronous writes. WorkspaceLive retains
  navigation, flashes and refreshing the project rail. Keeping the dialog
  preserves every workspace entry point and the selected track. SettingsSections
  owns only browser navigation and unsaved-input warnings, never secret values.
  """
  use RavixWeb, :live_component

  alias Ravix.Accounts.Access
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Previews
  alias Ravix.Projects
  alias Ravix.Projects.Machine.Rebuild
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
         pending: MapSet.new(),
         save_state: "",
         save_version: 0,
         confirmations: %{}
       )}

  @impl true
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

  defp settings_event("save-settings", %{"settings" => params}, socket) do
    attrs =
      params
      |> Map.take(~w(name runtime model instructions setup_script))
      |> put_packages(params)

    user = user(socket)
    id = project_id(socket)

    {:noreply,
     socket
     |> assign(
       settings_form: Form.new(:settings, Map.merge(socket.assigns.settings_form.params, params))
     )
     |> begin(:settings, fn -> Projects.update_settings(user, id, attrs) end)}
  end

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

  defp async_result(:settings, {:ok, response}, socket) do
    {:noreply,
     result(
       settle(socket, :settings),
       response,
       fn s, _ ->
         # The name may have changed, so the rail is wrong until the page
         # re-reads it. Saying so is this dialog's part; what to re-read is
         # the page's.
         send(self(), :project_settings_saved)

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

  defp async_result(:secret, {:ok, response}, socket) do
    {:noreply,
     result(
       settle(socket, :secret),
       response,
       fn s, _ -> s |> load() |> saved() |> flash(:info, "Secret updated.") end,
       :secret_form
     )}
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
      # The secret form is always blank: values are write-only, so there is
      # nothing to read back, and a key left in the box from the last save
      # invites somebody to overwrite a secret they meant to add beside.
      |> assign(secret_form: Form.new(:secret, %{"store" => "env"}))
    end)
  end

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
          phx-hook="SettingsSections"
          data-save-state={@save_state}
          data-save-version={@save_version}
          data-models={Jason.encode!(@settings.catalog.models)}
          data-model-labels={Jason.encode!(model_labels(@settings.catalog, @settings.model))}
          data-saved-model={@settings.model}
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
              <p class="settings-help">Give this project a recognizable name in your workspace.</p>
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
                Choose how the agent works. Applies to tracks opened after you save; open tracks keep their settings.
              </p>
              <.form
                :let={f}
                for={@settings_form}
                id="agent-settings-form"
                phx-target={@myself}
                phx-submit="save-settings"
              >
                <.input
                  field={f[:runtime]}
                  id="settings-runtime"
                  label="Agent"
                  type="select"
                  options={
                    RavixWeb.AgentName.settings_options(@settings.catalog.runtimes, f[:runtime].value)
                  }
                  aria-describedby="settings-runtime-help"
                />
                <p id="settings-runtime-help" class="settings-help">
                  The coding program used for new tracks. Choose Claude Code or Codex; an existing agent choice is retained.
                </p>
                <.input
                  field={f[:model]}
                  id="settings-model"
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
                  The model used by this agent. If the catalog is unavailable, your saved choice is retained.
                </p>
                <.input
                  type="textarea"
                  field={f[:instructions]}
                  id="settings-instructions"
                  label="Instructions"
                  rows="7"
                  aria-describedby="settings-instructions-help"
                />
                <p id="settings-instructions-help" class="settings-help">
                  Extra guidance for every new track, alongside Ravix’s instructions. For example: “Run focused tests before committing. Explain any accessibility changes.”
                </p>
                <button class="primary" phx-disable-with="Saving…" disabled={:settings in @pending}>Save agent</button>
              </.form>
            </section>
            <section
              id="settings-section-environment"
              data-settings-panel="environment"
              aria-labelledby="settings-environment-title"
              hidden
            >
              <h3 id="settings-environment-title" tabindex="-1">Environment</h3>
              <p class="settings-help">
                Prepare the machine’s disk. These changes apply when the machine is built, not when another track opens. Rebuild an existing machine to apply them; rebuilding discards its disk and closes every track.
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
                  Shell commands to prepare the project. For example: <code>npm ci</code>. Keep credentials in Secrets.
                </p>
                <.input
                  :for={kind <- ~w(apt pip npm)}
                  field={f[String.to_existing_atom(kind)]}
                  id={"packages-#{kind}"}
                  label={"#{kind} packages"}
                  aria-describedby="settings-packages-help"
                />
                <p id="settings-packages-help" class="settings-help">
                  Space- or comma-separated package names: apt for system tools (git curl), pip for Python (pytest), npm for JavaScript (typescript). Empty lists remove that manager’s packages from the configuration.
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
                Values are write-only and never shown again. Changes apply to tracks opened after you save; open tracks keep their settings.
              </p>
              <p class="settings-help">
                Environment secrets are available as environment variables on the machine. Vault secrets stay off the machine: Fountain’s egress broker substitutes them into outgoing requests. Choose the store your integration uses; the same key can exist in both.
              </p>
              <p class="settings-help">
                Add a new key, or enter an existing key to replace it. To remove a key, enter its name and store and submit an empty value.
              </p>
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
                A preview runs your app on the track’s machine so you can open it in your browser. These defaults are used when a track has no preview override; saving does not restart a running preview.
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
                  Relative to the project checkout, for example apps/web. Use . for the repository root.
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
