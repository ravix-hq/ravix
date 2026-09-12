defmodule RavixWeb.Live.SettingsDialog do
  @moduledoc """
  A project's settings, its secrets, its preview defaults, and the two
  irreversible buttons.

  Four forms that have nothing to do with each other beyond being reached
  from the same dialog, and until now all four lived in `WorkspaceLive`:
  five of its assigns, four of its `handle_event/3` clauses, one of its
  `handle_async/3` clauses, and a hundred lines of its template. That is the
  shape a React page has --- every dialog's state lifted to the screen that
  can open it --- and `RavixWeb.Live.PeopleDialog` already says why it is
  wrong here, having been the first of these to move.

  The cost of leaving it was not only size. `busy` was one boolean for the
  whole page, so the rebuild and delete buttons in this dialog were disabled
  while somebody was creating a *project* in a different one, and re-enabled
  by whichever of the two finished first. A flag that means "this page is
  doing something" cannot answer "may I press this", because the page is
  always doing something on behalf of somebody.

  ## What stays with the page

  Three things, and each is the page's by right:

    * **The flash.** `Phoenix.LiveView.put_flash/3` inside a component
      changes a socket nobody renders. The sentence is sent instead; see
      `RavixWeb.Live.Result.error/2`.
    * **The rail.** Saving settings renames the project, so the list on the
      left is wrong until it is re-read. This dialog says so and the page
      decides what to do about it.
    * **Where to go.** Rebuilding or deleting takes you off the project, and
      a component cannot patch the URL.

  ## What is still synchronous

  `update/2` reads `Ravix.Projects.settings/2`, which is a Fountain call, in
  the page's process. That is the same thing `WorkspaceLive` did before this
  and it is not made worse by moving --- a component runs in its parent's
  process --- but it is worth naming: it blocks the page while the dialog
  opens. Unlike the refreshes fixed in #102 it happens on a click rather
  than on a message nobody asked for, which is why it is a note here and not
  part of this change.
  """
  use RavixWeb, :live_component

  alias Ravix.Previews
  alias Ravix.Projects
  alias Ravix.Projects.Machine.Rebuild
  alias RavixWeb.Live.Form
  alias RavixWeb.Live.Params

  @packages ~w(apt pip npm)

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok, if(socket.assigns[:settings], do: socket, else: load(socket))}
  end

  @impl true
  def handle_event("save-settings", %{"settings" => params}, socket) do
    attrs =
      params
      |> Map.take(~w(name runtime model instructions setup_script))
      |> Map.put("packages", packages_from(params))

    {:noreply,
     result(
       assign(socket, settings_form: Form.new(:settings, params)),
       Projects.update_settings(user(socket), project_id(socket), attrs),
       fn s, _ ->
         # The name may have changed, so the rail is wrong until the page
         # re-reads it. Saying so is this dialog's part; what to re-read is
         # the page's.
         send(self(), :project_settings_saved)

         s
         |> load()
         |> flash(
           :info,
           "Settings saved. Open a new track to use updated instructions and secrets."
         )
       end,
       :settings_form
     )}
  end

  def handle_event("save-secret", %{"secret" => params}, socket) do
    # The store and the key go back into the form so a refusal can be
    # corrected. The value does not: a secret in an assign is a secret in the
    # page's state and in its next diff, which is the one thing this form
    # must not do, and `<.input type="password">` would render it straight
    # back into the box.
    kept = Map.drop(params, ["value"])

    {:noreply,
     result(
       assign(socket, secret_form: Form.new(:secret, kept)),
       Projects.update_settings(user(socket), project_id(socket), %{
         secret: Map.take(params, ~w(store key value))
       }),
       fn s, _ -> s |> load() |> flash(:info, "Secret updated.") end,
       :secret_form
     )}
  end

  def handle_event("save-preview-defaults", params, socket) do
    fields = Map.get(params, "preview_defaults", %{})
    config = if Params.flag(params, "clear"), do: nil, else: fields

    {:noreply,
     result(
       assign(socket, defaults_form: Form.new(:preview_defaults, fields)),
       Previews.set_defaults(user(socket), project_id(socket), config),
       fn s, defaults ->
         s |> show_defaults(defaults) |> flash(:info, "Preview defaults saved.")
       end,
       :defaults_form
     )}
  end

  # The typed confirmation is the gate; which of the two irreversible things
  # happens after it is decided by the clause, not by a string compared again
  # further down.
  def handle_event("project-danger", %{"action" => "rebuild", "confirm" => name}, socket),
    do: {:noreply, danger(socket, name, &Projects.rebuild/2)}

  def handle_event("project-danger", %{"action" => "delete", "confirm" => name}, socket),
    do: {:noreply, danger(socket, name, &Projects.destroy/2)}

  @impl true
  def handle_async(:danger, {:ok, response}, socket) do
    {:noreply,
     result(assign(socket, busy?: false), response, fn s, outcome ->
       # Both of these take you off the project: a rebuild closes every track
       # on it and a delete removes it outright.
       send(self(), :project_left_behind)
       report(s, outcome)
     end)}
  end

  def handle_async(:danger, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(busy?: false)
       |> flash(:error, "The operation could not finish. Refresh and try again.")}

  # ── loading ───────────────────────────────────────────────────────────

  defp load(socket) do
    result(socket, Projects.settings(user(socket), project_id(socket)), fn s, settings ->
      defaults =
        case Previews.defaults(user(s), project_id(s)) do
          {:ok, value} -> value
          _ -> nil
        end

      s
      |> assign(settings: settings, settings_form: settings_form(settings), busy?: false)
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

      socket
      |> assign(busy?: true)
      |> traced_async(:danger, fn -> call.(user, id) end)
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

  defp flash(socket, kind, message) do
    send(self(), {:flash, kind, message})
    socket
  end

  defp user(socket), do: socket.assigns.current_user
  defp project_id(socket), do: socket.assigns.project.id

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
        <.form
          :let={f}
          for={@settings_form}
          id="settings-form"
          phx-target={@myself}
          phx-submit="save-settings"
        >
          <.input field={f[:name]} id="settings-name" label="Name" required />
          <.input
            field={f[:runtime]}
            id="settings-runtime"
            label="Harness"
            list="runtime-options"
          />
          <datalist id="runtime-options">
            <option :for={runtime <- @settings.catalog.runtimes} value={runtime} />
          </datalist>
          <.input field={f[:model]} id="settings-model" label="Model" />
          <.input
            type="textarea"
            field={f[:instructions]}
            id="settings-instructions"
            label="Instructions"
            rows="5"
          />
          <.input
            type="textarea"
            field={f[:setup_script]}
            id="settings-setup"
            label="Setup script"
            rows="5"
          />
          <.input
            :for={kind <- ~w(apt pip npm)}
            field={f[String.to_existing_atom(kind)]}
            id={"packages-#{kind}"}
            label={"#{kind} packages"}
          />
          <button class="primary" phx-disable-with="Saving…">Save settings</button>
        </.form>
        <hr />
        <h3>Secrets</h3>
        <p>Values are write-only. Submit an empty value to remove a secret.</p>
        <p>Environment: {Enum.join(@settings.env_keys, ", ")}</p>
        <p>Vault: {Enum.join(@settings.vault_keys, ", ")}</p>
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
          <button class="primary" phx-disable-with="Saving…">Update secret</button>
        </.form>
        <hr />
        <h3>Preview defaults</h3>
        <.form
          :let={f}
          for={@defaults_form}
          id="preview-defaults-form"
          phx-target={@myself}
          phx-submit="save-preview-defaults"
        >
          <.input field={f[:directory]} id="default-directory" label="App directory" />
          <.input field={f[:command]} id="default-command" label="Command (must honor $PORT)" />
          <.input field={f[:readiness_path]} id="default-readiness" label="Readiness path" />
          <button class="primary">Save defaults</button><button
            name="clear"
            value="true"
            class="ghost"
          >Clear defaults</button>
        </.form>
        <hr />
        <h3>Machine and project</h3>
        <p>
          Rebuilding discards the machine and closes every track. Deleting also removes the project settings and secrets.
        </p>
        <form id="project-danger-form" phx-target={@myself} phx-submit="project-danger">
          <.input
            name="confirm"
            id="danger-confirm"
            label={"Type #{@project.name} to confirm"}
            value=""
            required
          />
          <button name="action" value="rebuild" class="ghost" disabled={@busy?}>
            Rebuild machine
          </button>
          <button name="action" value="delete" class="danger" disabled={@busy?}>
            Delete project
          </button>
        </form>
      </.dialog>
    </div>
    """
  end
end
