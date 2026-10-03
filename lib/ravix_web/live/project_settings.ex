defmodule RavixWeb.Live.ProjectSettings do
  @moduledoc """
  Owner-only project settings, `/p/:project/settings/:section`: five pages
  in the settings frame (`RavixWeb.Live.Settings`, RAV-72), laid out as
  RAV-74 has them.

    * **General**: the name, the repository, and the workspace the project
      is in, with the move to another.
    * **Access**: everyone who reaches the project and where their role
      comes from (RAV-75), the People dialog drawn as a page
      (`RavixWeb.Live.PeopleDialog`, `layout: :page`).
    * **Agent**: the agent, its model and the instructions.
    * **Machine**: the setup script, the packages, the variables, the
      secrets and the run script, behind one "Save & rebuild". Saving says
      first what it changes and how many open tracks the rebuild closes
      (`RavixWeb.Live.MachineChanges`); a change to the run script alone
      needs no new machine and just says "Save".
    * **Danger zone**: closing orphaned private tracks, changing the
      repository (RAV-76), rebuilding the machine, and deleting the
      project.

  The dialog's old tabs keep their URLs; `Settings.resolve/3` sends each to
  the part of the page it became.

  One Save a page, in the frame's unsaved-changes bar (RAV-38 decision 2).
  Only the page the URL names is drawn, and moving to another puts every
  form back to what is saved: leaving with changes was already asked about.

  Every event and every async result is checked against
  `Access.project_of/2` again, so settings stay the owner's however the
  page was reached. Secret values are never assigned: they stay in the
  browser's inputs until the confirmed save, and go to Fountain from the
  task that writes them. WorkspaceLive retains the route, flashes and
  refreshing the project rail.
  """
  use RavixWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Ravix.Accounts.{Access, Inference}
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Previews
  alias Ravix.Projects
  alias Ravix.Projects.EnvironmentVariables.Row
  alias Ravix.Projects.Machine.Rebuild
  alias Ravix.Tracks
  alias Ravix.Workspaces
  alias Ravix.Workspaces.Picker
  alias RavixWeb.Live.Form
  alias RavixWeb.Live.Hooks
  alias RavixWeb.Live.MachineChanges
  alias RavixWeb.Live.Settings
  alias RavixWeb.ModelName

  @stores ~w(env vault)

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
         save_version: 0,
         switching_agent: false,
         switch_confirmation: nil,
         confirmations: %{},
         move_targets: nil,
         move_confirmation: nil,
         move_taken: nil,
         secret_rows: [],
         secret_seq: 0,
         machine_review: nil,
         change_repository: change_repository_params(%{}),
         change_dialog: false,
         change_query: "",
         change_count: nil,
         repository_choices: nil
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

  def update(%{conductor_selection: selection, conductor_repository: repository}, socket) do
    {:noreply, socket} =
      Hooks.component(socket, fn ->
        apply_conductor_selection(socket, selection, repository)
      end)

    {:ok, socket}
  end

  def update(assigns, socket) do
    before = socket.assigns[:section]
    socket = assign(socket, assigns)

    socket =
      cond do
        is_nil(socket.assigns.settings) -> load(socket)
        before != socket.assigns.section -> reset_forms(socket)
        true -> socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event(event, params, socket) do
    case Access.project_of(user(socket), project_id(socket)) do
      # Nothing was read, so there is nothing drawn to act on.
      {:ok, _} when is_nil(socket.assigns.settings) -> {:noreply, socket}
      {:ok, _} -> settings_event(event, params, socket)
      {:error, reason} -> {:noreply, error(socket, reason)}
    end
  end

  # ── General ───────────────────────────────────────────────────────────

  defp settings_event("save-general", %{"settings" => params}, socket) do
    socket =
      assign(socket,
        switching_agent: false,
        settings_form: Form.new(:settings, Map.merge(socket.assigns.settings_form.params, params))
      )

    {:noreply, save_settings(socket, Map.take(params, ["name"]))}
  end

  defp settings_event("discard-general", _, socket),
    do: {:noreply, assign(socket, settings_form: settings_form(socket.assigns.settings))}

  defp settings_event("choose-move-target", %{"workspace" => id}, socket) do
    case socket.assigns.move_targets &&
           Enum.find(socket.assigns.move_targets.targets, &(&1.id == id)) do
      nil -> {:noreply, socket}
      target -> {:noreply, assign(socket, move_confirmation: target, move_taken: nil)}
    end
  end

  defp settings_event("cancel-move", _, socket),
    do: {:noreply, assign(socket, move_confirmation: nil)}

  defp settings_event("confirm-move", _, socket) do
    case socket.assigns.move_confirmation do
      %{id: workspace_id} ->
        user = user(socket)
        id = project_id(socket)

        {:noreply,
         begin(socket, :move, fn -> Workspaces.move_project(user, id, workspace_id) end)}

      nil ->
        {:noreply, socket}
    end
  end

  # ── Agent ─────────────────────────────────────────────────────────────

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
    do:
      {:noreply,
       assign(socket,
         settings_form: settings_form(socket.assigns.settings),
         switch_confirmation: nil
       )}

  defp settings_event("refresh-settings-agents", _, socket),
    do: {:noreply, refresh_agents(socket)}

  defp settings_event("save-agent", %{"settings" => params}, socket) do
    attrs = Map.take(params, ~w(runtime model instructions))

    switching =
      is_binary(attrs["runtime"]) and attrs["runtime"] != socket.assigns.settings.runtime and
        not Map.get(socket.assigns.settings, :default_only, false)

    socket =
      assign(socket,
        switching_agent: switching,
        switch_confirmation: nil,
        settings_form: Form.new(:settings, Map.merge(socket.assigns.settings_form.params, params))
      )

    if switching do
      user = user(socket)
      id = project_id(socket)
      shared_only? = Map.get(socket.assigns.settings, :shared_tracks) != nil

      {:noreply,
       begin(socket, :switch_preview, fn ->
         with {:ok, count} <- closing(user, id, shared_only?) do
           {:ok, %{attrs: attrs, count: count, shared_only?: shared_only?}}
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

  # ── Machine ───────────────────────────────────────────────────────────

  defp settings_event("edit-machine", params, socket),
    do: {:noreply, socket |> edit_machine(params) |> assign(machine_review: nil)}

  defp settings_event("add-env-var", _, socket) do
    {:noreply, update(socket, :variable_rows, &(&1 ++ [%Row{key: "", value: ""}]))}
  end

  defp settings_event("remove-env-var", %{"index" => index}, socket)
       when is_integer(index) and index >= 0,
       do: {:noreply, update(socket, :variable_rows, &List.delete_at(&1, index))}

  defp settings_event("remove-env-var", %{"index" => index}, socket) when is_binary(index) do
    case Integer.parse(index) do
      {index, ""} when index >= 0 ->
        {:noreply, update(socket, :variable_rows, &List.delete_at(&1, index))}

      _ ->
        {:noreply, socket}
    end
  end

  defp settings_event("add-secret", _, socket),
    do:
      {:noreply, add_secret_row(socket, %{store: "env", key: "", action: :set, existing: false})}

  # Replacing or removing a key the project holds: only one it does hold,
  # and once a save.
  defp settings_event(
         "change-secret",
         %{"store" => store, "key" => key, "action" => action},
         socket
       )
       when store in @stores and action in ["replace", "remove"] do
    held =
      if store == "vault",
        do: socket.assigns.settings.vault_keys,
        else: socket.assigns.settings.env_keys

    if key in held and
         not Enum.any?(socket.assigns.secret_rows, &(&1.store == store and &1.key == key)) do
      action = if action == "remove", do: :remove, else: :set

      {:noreply,
       add_secret_row(socket, %{store: store, key: key, action: action, existing: true})}
    else
      {:noreply, socket}
    end
  end

  defp settings_event("change-secret", _, socket), do: {:noreply, socket}

  defp settings_event("drop-secret", %{"row" => row}, socket) do
    case Integer.parse(row) do
      {id, ""} ->
        {:noreply, update(socket, :secret_rows, &Enum.reject(&1, fn r -> r.id == id end))}

      _ ->
        {:noreply, socket}
    end
  end

  defp settings_event("discard-machine", _, socket),
    do: {:noreply, reset_machine(socket)}

  defp settings_event("cancel-machine-review", _, socket),
    do: {:noreply, assign(socket, machine_review: nil)}

  defp settings_event("save-machine", params, socket) do
    socket = edit_machine(socket, params)
    review = socket.assigns.machine_review

    confirmed? = params["machine_confirm"] == "true" and review != nil

    case machine_plan(socket, params) do
      {:ok, %{lines: []}} ->
        {:noreply,
         socket
         |> assign(machine_review: nil)
         |> saved()
         |> flash(:info, "Nothing to save: this is what the machine already has.")}

      # The owner confirmed the summary they were shown. A form that no longer
      # matches it (it cannot change under the question, but a forged submit
      # can) is asked about again rather than saved.
      {:ok, plan} ->
        if confirmed? and review.lines == plan.lines and review.rebuild? == plan.rebuild?,
          do: {:noreply, socket |> assign(machine_review: nil) |> save_machine(plan)},
          else: {:noreply, socket |> assign(machine_review: nil) |> review_machine(plan)}

      {:error, reason} ->
        {:noreply, socket |> assign(machine_review: nil) |> error(reason)}
    end
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

  # ── Danger zone ───────────────────────────────────────────────────────

  defp settings_event("close-orphaned-private", %{"confirm" => name}, socket) do
    if name == socket.assigns.project.name do
      user = user(socket)
      id = project_id(socket)
      {:noreply, begin(socket, :orphan_close, fn -> Tracks.close_orphaned_private(user, id) end)}
    else
      {:noreply, flash(socket, :error, "Type the project name to confirm.")}
    end
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

  # RAV-76: Change repository, a dialog in three steps: pick one of the
  # repositories the App reads, read what happens (how many open tracks
  # close), type the project's name. What was picked and typed is kept, so
  # a refusal leaves the dialog as it was.
  defp settings_event("open-change-repository", _, socket) do
    user = user(socket)
    id = project_id(socket)
    shared_only? = Map.get(socket.assigns.settings, :shared_tracks) != nil

    {:noreply,
     socket
     |> assign(
       change_dialog: true,
       change_query: "",
       change_count: nil,
       change_repository: change_repository_params(%{})
     )
     |> load_repository_choices()
     |> traced_async(:change_count, fn -> closing(user, id, shared_only?) end)}
  end

  defp settings_event("cancel-change-repository", _, socket) do
    if MapSet.member?(socket.assigns.pending, :change_repository),
      do: {:noreply, socket},
      else: {:noreply, assign(socket, change_dialog: false)}
  end

  defp settings_event("filter-change-repository", %{"q" => query}, socket)
       when is_binary(query),
       do: {:noreply, assign(socket, change_query: String.slice(query, 0, 200))}

  # Only a repository the dialog offered can be picked; a forged one is
  # ignored (and `change_repository/3` would ask GitHub again regardless).
  defp settings_event("pick-change-repository", %{"repo" => repo}, socket) do
    if offered?(socket, repo),
      do: {:noreply, update(socket, :change_repository, &Map.put(&1, "repo", repo))},
      else: {:noreply, socket}
  end

  defp settings_event("edit-change-repository", params, socket) do
    {:noreply,
     update(
       socket,
       :change_repository,
       &Map.put(&1, "confirm", change_repository_params(params)["confirm"])
     )}
  end

  defp settings_event("change-repository", params, socket) do
    confirm = change_repository_params(params)["confirm"]
    socket = update(socket, :change_repository, &Map.put(&1, "confirm", confirm))
    repo = socket.assigns.change_repository["repo"]

    cond do
      not socket.assigns.change_dialog or not offered?(socket, repo) ->
        {:noreply, socket}

      confirm != socket.assigns.project.name ->
        {:noreply, flash(socket, :error, "Type the project name to confirm.")}

      true ->
        user = user(socket)
        id = project_id(socket)

        {:noreply,
         begin(socket, :change_repository, fn ->
           {repo, Projects.change_repository(user, id, repo)}
         end)}
    end
  end

  defp settings_event(_event, _params, socket), do: {:noreply, socket}

  # ── answers ───────────────────────────────────────────────────────────

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
         # re-reads it. Saying so is this component's part; what to re-read is
         # the page's.
         if s.assigns.switching_agent do
           send(self(), :project_left_behind)
         else
           send(self(), :project_settings_saved)
         end

         s |> load() |> saved() |> flash(:info, "Settings saved.")
       end,
       :settings_form
     )}
  end

  defp async_result(:switch_preview, {:ok, response}, socket) do
    {:noreply,
     result(settle(socket, :switch_preview), response, fn s, confirmation ->
       assign(s, switch_confirmation: confirmation)
     end)}
  end

  defp async_result(:machine_review, {:ok, response}, socket) do
    {:noreply,
     result(settle(socket, :machine_review), response, fn s, review ->
       assign(s, machine_review: review)
     end)}
  end

  defp async_result(:machine, {:ok, {:ok, %{rebuilt: outcome}}}, socket) do
    send(self(), :project_settings_saved)

    message =
      if outcome == :none,
        do: "Machine settings saved.",
        else: "Machine settings saved. The machine is being rebuilt."

    {:noreply,
     socket
     |> settle(:machine)
     |> load()
     |> saved()
     |> flash(:info, message)
     |> report(outcome)}
  end

  defp async_result(:machine, {:ok, {:error, %{done: done, step: step, reason: reason}}}, socket) do
    socket = settle(socket, :machine)
    sentence = RavixWeb.Error.from(reason).message

    # Some of it may have been written: the page compares against what is
    # saved now, and a secret that went through is not offered again.
    socket = refresh_saved(socket, done)

    socket =
      case step do
        {:run, _} -> refuse_run(socket, reason)
        _ -> socket
      end

    saved_part = if done == [], do: "", else: "Saved #{join(Enum.map(done, &step_label/1))}. "

    if step == :rebuild,
      do:
        {:noreply,
         socket
         |> load()
         |> saved()
         |> flash(:error, "#{saved_part}The machine was not rebuilt: #{sentence}")},
      else:
        {:noreply,
         flash(socket, :error, "#{saved_part}Could not save #{step_label(step)}: #{sentence}")}
  end

  defp async_result(:secret_confirmation, {:ok, response}, socket) do
    {:noreply,
     result(settle(socket, :secret_confirmation), response, fn s, _ ->
       s
       |> load()
       |> flash(
         :info,
         "Secret changes are unlocked. Save the intended value again if needed, then rebuild dedicated tracks to apply it."
       )
     end)}
  end

  defp async_result(:orphan_close, {:ok, response}, socket) do
    {:noreply,
     result(settle(socket, :orphan_close), response, fn s, count ->
       s |> load() |> flash(:info, "Closing #{count} private tracks with no remaining members.")
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

  defp async_result(:repository_choices, {:ok, {:ok, repos}}, socket),
    do: {:noreply, assign(socket, repository_choices: repos)}

  # Nothing to offer is what the dialog says; the reason is flashed.
  defp async_result(:repository_choices, {:ok, {:error, reason}}, socket),
    do: {:noreply, socket |> assign(repository_choices: []) |> error(reason)}

  defp async_result(:change_count, {:ok, {:ok, count}}, socket),
    do: {:noreply, assign(socket, change_count: count)}

  # Uncounted, the review says "every open track" instead of a number.
  defp async_result(:change_count, {:ok, {:error, _reason}}, socket),
    do: {:noreply, socket}

  defp async_result(:change_repository, {:ok, {repo, response}}, socket) do
    socket = settle(socket, :change_repository)
    name = socket.assigns.project.name

    case response do
      {:ok, outcome} ->
        # The rail and the header name the repository.
        send(self(), :project_settings_saved)

        {:noreply,
         socket
         |> changed_repository()
         |> flash(
           :info,
           "#{name} now uses #{repo}. Its tracks were closed and the machine is being rebuilt."
         )
         |> report(outcome)}

      {:error, {:not_rebuilt, reason}} ->
        send(self(), :project_settings_saved)

        {:noreply,
         socket
         |> changed_repository()
         |> flash(
           :error,
           "#{name} now uses #{repo}, but the machine was not rebuilt: #{RavixWeb.Error.from(reason).message} Rebuild it from this page."
         )}

      {:error, reason} ->
        {:noreply, error(socket, reason)}
    end
  end

  # The target already has this repository: say which project, so the owner
  # can open that one instead, rather than a bare refusal.
  defp async_result(:move, {:ok, {:error, {:repository_taken, taken}}}, socket),
    do: {:noreply, socket |> settle(:move) |> assign(move_confirmation: nil, move_taken: taken)}

  defp async_result(:move, {:ok, response}, socket) do
    {:noreply,
     result(settle(socket, :move), response, fn s, _moved ->
       target = s.assigns.move_confirmation
       # The rail lists projects by workspace, so it re-reads.
       send(self(), :project_settings_saved)

       s
       |> assign(move_confirmation: nil, move_taken: nil)
       |> load()
       |> flash(
         :info,
         "Moved to #{if target, do: workspace_label(target), else: "the workspace"}."
       )
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

  # One of the page's writes, started off this process and named in
  # `pending` until its answer or its exit settles it.
  defp begin(socket, name, call) do
    if MapSet.size(socket.assigns.pending) > 0 do
      socket
    else
      socket
      |> update(:pending, &MapSet.put(&1, name))
      |> traced_async(name, call)
    end
  end

  defp settle(socket, name), do: update(socket, :pending, &MapSet.delete(&1, name))

  # The unsaved-changes bar goes when this moves; see `Settings.unsaved_changes/1`.
  defp saved(socket), do: update(socket, :save_version, &(&1 + 1))

  # How many open tracks a rebuild closes, as far as the owner can see: all
  # of them on a shared machine, the ones sharing it when tracks may have
  # machines of their own.
  defp closing(user, id, shared_only?) do
    with {:ok, tracks} <- Tracks.list(user, id) do
      {:ok,
       if(shared_only?,
         do: Enum.count(tracks, &(&1.sandbox_layout == :shared)),
         else: length(tracks)
       )}
    end
  end

  defp apply_conductor_selection(socket, selection, repository) do
    with {:ok, project} <- Access.project_of(user(socket), project_id(socket)),
         true <- repository == {project.repo_full_name, project.default_branch || "main"},
         true <- socket.assigns.section == "machine" and MapSet.size(socket.assigns.pending) == 0 do
      environment = socket.assigns.environment_form.params
      run = socket.assigns.defaults_form.params

      environment =
        if selection.setup,
          do: Map.put(environment, "setup_script", selection.setup),
          else: environment

      run = if selection.run, do: Map.merge(run, selection.run), else: run

      {:noreply,
       assign(socket,
         environment_form: Form.new(:settings, environment),
         defaults_form: Form.new(:preview_defaults, run),
         machine_review: nil
       )}
    else
      {:error, reason} -> {:noreply, error(socket, reason)}
      false -> {:noreply, socket}
    end
  end

  # ── the machine page ──────────────────────────────────────────────────

  defp edit_machine(socket, params) do
    socket
    |> assign(
      environment_form:
        Form.new(
          :settings,
          Map.take(
            params["settings"] || socket.assigns.environment_form.params,
            environment_keys()
          )
        ),
      defaults_form:
        Form.new(
          :preview_defaults,
          Map.take(
            params["preview_defaults"] || socket.assigns.defaults_form.params,
            MachineChanges.run_fields()
          )
        ),
      variable_rows:
        if(Map.has_key?(params, "env_vars"),
          do: variable_rows(params),
          else: socket.assigns.variable_rows
        )
    )
    |> update(:secret_rows, &secret_rows(&1, params["secrets"]))
  end

  defp environment_keys, do: ["setup_script" | MachineChanges.managers()]

  # A new row's store and name are the form's; a held key's row keeps the
  # store and name it was opened for. Values are never kept.
  defp secret_rows(rows, params) when is_map(params) do
    Enum.map(rows, fn
      %{existing: false} = row ->
        typed = Map.get(params, Integer.to_string(row.id), %{})
        store = if typed["store"] in @stores, do: typed["store"], else: row.store
        %{row | store: store, key: to_string(typed["key"] || row.key)}

      row ->
        row
    end)
  end

  defp secret_rows(rows, _params), do: rows

  defp add_secret_row(socket, row) do
    id = socket.assigns.secret_seq + 1

    socket
    |> assign(secret_seq: id)
    |> update(:secret_rows, &(&1 ++ [Map.put(row, :id, id)]))
  end

  defp machine_plan(socket, params) do
    values = params["secrets"] || %{}

    secrets =
      Enum.map(socket.assigns.secret_rows, fn row ->
        value = if row.action == :set, do: get_in(values, [Integer.to_string(row.id), "value"])

        %{
          store: row.store,
          key: row.key,
          action: row.action,
          existing: row.existing,
          value: if(is_binary(value), do: value)
        }
      end)

    MachineChanges.plan(
      socket.assigns.settings,
      socket.assigns.preview_defaults,
      socket.assigns.environment_form.params,
      socket.assigns.variable_rows,
      secrets,
      socket.assigns.defaults_form.params
    )
  end

  # The question before the save: what changes and, when it rebuilds, how
  # many tracks close. Only the plan's lines are kept; its secret values go
  # nowhere until the confirmed submit brings them again.
  defp review_machine(socket, plan) do
    user = user(socket)
    id = project_id(socket)
    lines = plan.lines
    rebuild? = plan.rebuild? and rebuilds?(socket.assigns.settings)
    shared_only? = Map.get(socket.assigns.settings, :shared_tracks) != nil

    begin(socket, :machine_review, fn ->
      count = if rebuild?, do: closing(user, id, shared_only?), else: {:ok, 0}

      with {:ok, count} <- count do
        {:ok,
         %{
           lines: lines,
           rebuild?: plan.rebuild?,
           rebuilds?: rebuild?,
           count: count,
           shared_only?: shared_only?
         }}
      end
    end)
  end

  # Everything, in the order a machine is built from it, then the new
  # machine. The first refusal stops the rest and says what did go in.
  defp save_machine(socket, plan) do
    user = user(socket)
    id = project_id(socket)
    rebuild? = plan.rebuild? and rebuilds?(socket.assigns.settings)

    begin(socket, :machine, fn -> write_machine(user, id, plan, rebuild?) end)
  end

  defp write_machine(user, id, plan, rebuild?) do
    steps =
      if(plan.environment,
        do: [{:environment, fn -> Projects.update_settings(user, id, plan.environment) end}],
        else: []
      ) ++
        Enum.map(plan.secrets, fn secret ->
          {{:secret, secret.key},
           fn -> Projects.update_settings(user, id, %{"secret" => secret_attrs(secret)}) end}
        end) ++
        if(plan.run == :keep,
          do: [],
          else: [{{:run, plan.run}, fn -> Previews.set_defaults(user, id, plan.run) end}]
        )

    done =
      Enum.reduce_while(steps, {:ok, []}, fn {step, call}, {:ok, done} ->
        case call.() do
          {:ok, _} -> {:cont, {:ok, done ++ [step]}}
          {:error, reason} -> {:halt, {:error, %{done: done, step: step, reason: reason}}}
        end
      end)

    with {:ok, done} <- done, do: rebuild(user, id, rebuild?, done)
  end

  defp rebuild(_user, _id, false, _done), do: {:ok, %{rebuilt: :none}}

  defp rebuild(user, id, true, done) do
    case Projects.rebuild(user, id) do
      {:ok, outcome} -> {:ok, %{rebuilt: outcome}}
      {:error, reason} -> {:error, %{done: done, step: :rebuild, reason: reason}}
    end
  end

  defp secret_attrs(%{action: :remove} = secret),
    do: %{"store" => secret.store, "key" => String.trim(secret.key), "value" => ""}

  defp secret_attrs(secret),
    do: %{"store" => secret.store, "key" => String.trim(secret.key), "value" => secret.value}

  defp step_label(:environment), do: "the setup, packages and variables"
  defp step_label({:secret, key}), do: "secret #{String.trim(key)}"
  defp step_label({:run, _}), do: "the run script"
  defp step_label(:rebuild), do: "the rebuild"

  defp join([one]), do: one
  defp join(many), do: Enum.join(Enum.drop(many, -1), ", ") <> " and " <> List.last(many)

  defp refuse_run(socket, reason) do
    case Form.refuse(socket.assigns.defaults_form, reason) do
      {:ok, form} -> assign(socket, defaults_form: form)
      :error -> socket
    end
  end

  # After a save that stopped: the saved settings are read again for the
  # comparison, the secrets that went in leave the list, and what is still
  # in the form stays.
  defp refresh_saved(socket, done) do
    written = for {:secret, key} <- done, do: key

    socket =
      update(socket, :secret_rows, fn rows -> Enum.reject(rows, &(&1.key in written)) end)

    socket =
      case Projects.settings(user(socket), project_id(socket)) do
        {:ok, settings} -> assign(socket, settings: settings)
        _ -> socket
      end

    socket =
      case Previews.defaults(user(socket), project_id(socket)) do
        {:ok, defaults} -> assign(socket, preview_defaults: defaults)
        _ -> socket
      end

    refresh_secret_confirmation(socket)
  end

  # A secret write Fountain did not confirm locks further secret changes
  # until the owner says it finished; the project row is what knows.
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

  # A project whose tracks all have machines of their own has no project
  # machine to rebuild: its Machine page saves without one.
  defp rebuilds?(settings), do: not Map.get(settings, :default_only, false)

  # ── loading ───────────────────────────────────────────────────────────

  defp variable_rows(params),
    do:
      params
      |> Map.get("env_vars", %{})
      |> Enum.sort_by(fn {index, _} -> Integer.parse(index) end)
      |> Enum.map(fn {_, row} -> Row.new(row) end)

  defp saved_variable_rows(settings) do
    settings
    |> Map.get(:env_vars, %{})
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> %Row{key: key, value: value} end)
  end

  defp load(socket) do
    result(socket, Projects.settings(user(socket), project_id(socket)), fn s, settings ->
      defaults =
        case Previews.defaults(user(s), project_id(s)) do
          {:ok, value} -> value
          _ -> nil
        end

      s
      |> assign(
        settings: settings,
        preview_defaults: defaults,
        orphan_count:
          case Tracks.orphan_private_count(user(s), project_id(s)) do
            {:ok, count} -> count
            _ -> 0
          end
      )
      |> reset_forms()
      |> refresh_agents()
      |> assign(move_targets: move_targets(s))
    end)
  end

  # Every page's forms, as saved: on load, after a save, and on moving to
  # another page, whose leaving was already asked about.
  defp reset_forms(socket) do
    socket
    |> assign(
      settings_form: settings_form(socket.assigns.settings),
      switch_confirmation: nil,
      confirmations: %{},
      move_confirmation: nil,
      change_repository: change_repository_params(%{}),
      change_dialog: false
    )
    |> reset_machine()
  end

  defp reset_machine(socket) do
    settings = socket.assigns.settings

    assign(socket,
      environment_form: Form.new(:settings, MachineChanges.environment_params(settings)),
      defaults_form:
        Form.new(:preview_defaults, MachineChanges.run_params(socket.assigns.preview_defaults)),
      variable_rows: saved_variable_rows(settings),
      secret_rows: [],
      machine_review: nil
    )
  end

  # Nil while workspaces are switched off, which hides the part.
  defp move_targets(socket) do
    case Workspaces.move_targets(user(socket), project_id(socket)) do
      {:ok, targets} -> targets
      {:error, _} -> nil
    end
  end

  defp edit_agent(socket, params) do
    assign(socket,
      settings_form: Form.new(:settings, Map.merge(socket.assigns.settings_form.params, params))
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
      socket.assigns.settings != nil and socket.assigns.section == "agent" and
        id == panel_id(socket) and
        socket.assigns.settings_form[:runtime].value in ["claude", "codex"] and
        not usable?(socket.assigns.agents, socket.assigns.settings_form[:runtime].value)

  defp settings_form(settings) do
    Form.new(:settings, %{
      "name" => settings.name,
      "runtime" => settings.runtime,
      "model" => settings.model,
      "instructions" => settings.instructions
    })
  end

  # What the dialog holds: the repository picked from its list (nil until
  # one is) and the name typed.
  defp change_repository_params(params),
    do: %{"repo" => nil, "confirm" => str_param(params["confirm"], 200)}

  defp str_param(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp str_param(_value, _max), do: ""

  defp load_repository_choices(%{assigns: %{repository_choices: nil}} = socket) do
    user = user(socket)
    id = project_id(socket)

    socket
    |> assign(repository_choices: :loading)
    |> traced_async(:repository_choices, fn -> Projects.repository_choices(user, id) end)
  end

  defp load_repository_choices(socket), do: socket

  defp offered?(socket, repo) do
    is_binary(repo) and is_list(socket.assigns.repository_choices) and
      Enum.any?(socket.assigns.repository_choices, &(&1.repo == repo))
  end

  # After a change, whichever way it went: the dialog closes, and the next
  # one reads the choices again, which now include the old repository.
  defp changed_repository(socket) do
    socket
    |> assign(
      change_dialog: false,
      change_repository: change_repository_params(%{}),
      repository_choices: nil
    )
    |> load()
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
  # refusal.
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

  defp shown, do: Enum.map(Settings.sections(:project), &elem(&1, 0))

  defp workspace_label(%{kind: :personal}), do: "your personal workspace"
  defp workspace_label(%{name: name}), do: name

  defp model_options(values, current) do
    Enum.map(Enum.uniq(values ++ List.wrap(current)), &{ModelName.friendly(&1), &1})
  end

  # A repository is linked when it is spelled as GitHub's `owner/name`.
  defp github_url(repo) when is_binary(repo) do
    if Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, repo),
      do: "https://github.com/#{repo}"
  end

  defp github_url(_repo), do: nil

  defp switching?(settings, form),
    do:
      form[:runtime].value != settings.runtime and
        not Map.get(settings, :default_only, false)

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(n, noun), do: "#{n} #{noun}s"

  # The crumb and the nav heading (RAV-128): a project's settings sit inside
  # its workspace, so a workspace project reads bare, and a legacy project
  # still says whose it is.
  defp project_label(project), do: Projects.View.label(project, project.workspace_id)

  # ── the page ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="settings-host">
      <Settings.frame
        kind={:project}
        section={@section}
        crumbs={[project_label(@project)]}
        nav={Settings.project_groups(@project.id, project_label(@project), shown())}
      >
        <div class="settings-content" id={"settings-section-#{@section}"}>
          <%!-- Access is Ravix's own; the rest is read from Fountain, which
            can be unreachable. --%>
          {cond do
            @section == "access" -> access(assigns)
            is_nil(@settings) -> unavailable(assigns)
            @section == "general" -> general(assigns)
            @section == "agent" -> agent(assigns)
            @section == "machine" -> machine(assigns)
            @section == "danger" -> danger_zone(assigns)
          end}
        </div>
      </Settings.frame>
    </div>
    """
  end

  defp unavailable(assigns) do
    ~H"""
    <p id="settings-unavailable" class="settings-help" role="status">
      These settings could not be read just now. Reload the page to try again.
    </p>
    """
  end

  defp general(assigns) do
    ~H"""
    <Settings.unsaved_changes
      id="project-general"
      form="settings-form"
      saved={@save_version}
      discard="discard-general"
      target={@myself}
    >
      <.form
        :let={f}
        for={@settings_form}
        id="settings-form"
        phx-target={@myself}
        phx-submit="save-general"
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
      </.form>
    </Settings.unsaved_changes>
    <section id="general-repository" class="settings-part" aria-labelledby="general-repository-title">
      <h2 id="general-repository-title">Repository</h2>
      <p :if={@project.repo} class="settings-repo">
        <code>{@project.repo}</code>
        <a
          :if={github_url(@project.repo)}
          id="general-repository-link"
          href={github_url(@project.repo)}
          target="_blank"
          rel="noopener noreferrer"
        >Open on GitHub ↗</a>
      </p>
      <p :if={!@project.repo} class="settings-help">
        This project has no repository: its tracks start from an empty directory.
      </p>
      <p :if={@project.repo} class="settings-help">
        Every track is a branch of this repository.
      </p>
    </section>
    <section
      :if={@move_targets}
      id="general-workspace"
      class="settings-part"
      aria-labelledby="general-workspace-title"
    >
      <h2 id="general-workspace-title">Workspace</h2>
      <p class="settings-help">
        {if @move_targets.current,
          do: "This project is in #{workspace_label(@move_targets.current)}.",
          else: "This project is not in a workspace yet."} Moving it keeps its tracks, threads, machine, settings and secrets.
      </p>
      <p :if={@move_targets.duplicate_of} id="move-duplicate" class="settings-help">
        This project is a legacy duplicate of
        <.link navigate={"/p/#{@move_targets.duplicate_of}"}>another project</.link>
        for the same repository, so it cannot be moved. Keep working in that one, or resolve the duplicate first.
      </p>
      <p
        :if={@move_targets.targets == [] and is_nil(@move_targets.duplicate_of)}
        id="move-no-targets"
        class="settings-help"
      >
        You can move it only into a workspace where you are an owner or admin, and you are not one of any other.
      </p>
      <div
        :if={@move_targets.targets != []}
        id="move-targets"
        role="group"
        aria-label="Move to workspace"
      >
        <button
          :for={workspace <- @move_targets.targets}
          id={"move-to-#{workspace.id}"}
          type="button"
          class="ghost"
          phx-click="choose-move-target"
          phx-value-workspace={workspace.id}
          phx-target={@myself}
          aria-pressed={
            to_string(@move_confirmation != nil and @move_confirmation.id == workspace.id)
          }
          disabled={MapSet.size(@pending) > 0}
        >
          Move to {workspace_label(workspace)}…
        </button>
      </div>
      <p :if={@move_taken} id="move-taken" role="alert">
        {@move_taken.workspace} already has a project for this repository: <.link navigate={"/p/#{@move_taken.id}"}>{@move_taken.name}</.link>. Open that one instead, or move or delete it first.
      </p>
      <div
        :if={@move_confirmation}
        id="move-confirmation"
        role="alertdialog"
        aria-labelledby="move-confirmation-title"
        aria-describedby="move-confirmation-body"
      >
        <h3 id="move-confirmation-title">
          Move {@project.name} to {workspace_label(@move_confirmation)}?
        </h3>
        <ul id="move-confirmation-body">
          <li>
            Members of {workspace_label(@move_confirmation)} will see this project and its workspace-visible tracks, and can start tracks of their own.
          </li>
          <li>Private tracks stay private.</li>
          <li>People you added to the project or to a track keep their access.</li>
          <li>
            Invitations nobody has accepted yet and invite links stop working. From then on you can share only with members of {workspace_label(
              @move_confirmation
            )}.
          </li>
          <li :if={@move_targets.current}>
            Members of {workspace_label(@move_targets.current)} who were not added to the project or a track lose access, including private tracks shared with them there.
          </li>
        </ul>
        <button
          id="confirm-move"
          class="primary"
          phx-click="confirm-move"
          phx-target={@myself}
          phx-mounted={JS.focus()}
          disabled={MapSet.size(@pending) > 0}
        >
          Move project
        </button>
        <button type="button" phx-click="cancel-move" phx-target={@myself}>Cancel</button>
      </div>
    </section>
    """
  end

  defp access(assigns) do
    ~H"""
    <.live_component
      module={RavixWeb.Live.PeopleDialog}
      id="project-access"
      layout={:page}
      scope={:project}
      project={@project}
      subject_id={@project.id}
      current_user={@current_user}
      session_hash={@session_hash}
    />
    """
  end

  defp agent(assigns) do
    assigns = assign(assigns, :runtime, assigns.settings_form[:runtime].value)

    ~H"""
    <p :if={Map.get(@settings, :default_only, false)} class="settings-help">
      Changes the default agent for new threads. Existing threads keep their agent.
    </p>
    <p :if={Map.get(@settings, :shared_tracks) not in [nil, 0]} class="settings-help">
      {@settings.shared_tracks} {if @settings.shared_tracks == 1,
        do: "track still shares",
        else: "tracks still share"} the project machine
    </p>
    <p :if={not Map.get(@settings, :default_only, false)} class="settings-help">
      These actions also affect private tracks you cannot see. Switching agents rebuilds the machine, closes every track and loses unpushed work on its disk. Model and instruction changes apply to new tracks.
    </p>
    <Settings.unsaved_changes
      id="project-agent"
      form="agent-settings-form"
      saved={@save_version}
      save_label={if switching?(@settings, @settings_form), do: "Switch & rebuild", else: "Save"}
      discard="discard-agent"
      target={@myself}
    >
      <div class="field" role="group" aria-label="Agent">
        <div class="agent-choices">
          <button
            :for={{label, agent} <- RavixWeb.AgentName.options()}
            type="button"
            id={"settings-agent-#{agent}"}
            class={["agent-choice", @runtime == agent && "on"]}
            aria-pressed={to_string(@runtime == agent)}
            phx-click={
              JS.dispatch("unsaved:dirty")
              |> JS.push("choose-settings-agent", value: %{agent: agent}, target: @myself)
            }
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
        data-unsaved-ignore
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
        phx-submit="save-agent"
      >
        <div class="field">
          <input type="hidden" name="settings[runtime]" id="settings-runtime" value={@runtime} />
          <p :for={{message, _} <- f[:runtime].errors} class="error">{message}</p>
          <p :if={@runtime not in ["claude", "codex"]} class="settings-help">
            Current agent: {RavixWeb.AgentName.label(@runtime)}. Choose Claude Code or Codex to switch.
          </p>
        </div>
        <.input
          field={f[:model]}
          id="settings-model"
          disabled={@switch_confirmation != nil or (@switching_agent and MapSet.size(@pending) > 0)}
          label="Model"
          type="select"
          options={
            model_options(Catalog.models_for(@settings.catalog, f[:runtime].value), f[:model].value)
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
          disabled={@switch_confirmation != nil or (@switching_agent and MapSet.size(@pending) > 0)}
          label="Instructions"
          rows="7"
          aria-describedby="settings-instructions-help"
        />
        <p id="settings-instructions-help" class="settings-help">
          Guidance added to every new track, such as “Run tests before committing.”
        </p>
      </.form>
      <div
        :if={@switch_confirmation}
        id="agent-switch-confirmation"
        role="group"
        aria-label="Confirm agent switch"
        phx-remove={JS.focus(to: "#project-agent-bar [data-unsaved-save]")}
      >
        <p>
          This closes {@switch_confirmation.count} open {if @switch_confirmation.count == 1,
            do: "track",
            else: "tracks"} visible to you, plus any private tracks you cannot see, and discards the machine's disk, including unpushed work.
          <span :if={Map.get(@switch_confirmation, :shared_only?, false)}>Dedicated tracks are unaffected.</span>
        </p>
        <button
          id="confirm-agent-switch"
          class="primary"
          phx-click="confirm-agent-switch"
          phx-target={@myself}
          phx-mounted={JS.focus()}
          disabled={MapSet.size(@pending) > 0}
        >
          Rebuild and switch
        </button>
        <button type="button" phx-click="cancel-agent-switch" phx-target={@myself}>
          Cancel
        </button>
      </div>
    </Settings.unsaved_changes>
    """
  end

  defp machine(assigns) do
    ~H"""
    <p :if={rebuilds?(@settings) and is_nil(Map.get(@settings, :shared_tracks))} class="settings-help">
      The machine is built from everything on this page. Saving a change rebuilds it: its disk is discarded and every open track closes, including private tracks you cannot see, and unpushed work on that disk is lost. A change to the run script alone saves without a rebuild.
    </p>
    <p :if={rebuilds?(@settings) and Map.get(@settings, :shared_tracks) != nil} class="settings-help">
      The project machine is built from everything on this page. Saving a change rebuilds it and closes the tracks that share it; dedicated tracks are unaffected. A change to the run script alone saves without a rebuild.
    </p>
    <p :if={not rebuilds?(@settings)} class="settings-help">
      Every track here has a machine of its own. Changes apply to tracks opened from now on.
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
    <Settings.unsaved_changes
      id="project-machine"
      form="machine-form"
      saved={@save_version}
      save_label={if rebuilds?(@settings), do: "Save & rebuild", else: "Save"}
      discard="discard-machine"
      target={@myself}
    >
      <.live_component
        module={RavixWeb.Live.ConductorSetupImport}
        id={"conductor-setup-#{@project.id}"}
        settings_id={@id}
        project={@project}
        current_user={@current_user}
        session_hash={@session_hash}
      />
      <form
        id="machine-form"
        phx-target={@myself}
        phx-change="edit-machine"
        phx-submit="save-machine"
      >
        <section
          id="machine-environment"
          class="settings-part"
          aria-labelledby="machine-environment-title"
        >
          <h2 id="machine-environment-title">Setup</h2>
          <.input
            type="textarea"
            field={@environment_form[:setup_script]}
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
            :for={kind <- MachineChanges.managers()}
            field={@environment_form[String.to_existing_atom(kind)]}
            id={"packages-#{kind}"}
            label={"#{kind} packages"}
            aria-describedby="settings-packages-help"
          />
          <p id="settings-packages-help" class="settings-help">
            Separate names with spaces or commas. Leave blank to remove that package list.
          </p>
        </section>
        <section
          id="machine-variables"
          class="settings-part"
          aria-labelledby="machine-variables-title"
        >
          <h2 id="machine-variables-title">Environment variables</h2>
          <p class="settings-help">
            These values are visible to anyone who can see project settings. Keep secrets in Secrets.
            Up to 100 variables; names up to 200 bytes and values up to 16 KiB.
          </p>
          <fieldset>
            <legend class="sr-only">Readable environment variables</legend>
            <div
              :for={{row, index} <- Enum.with_index(@variable_rows)}
              id={"env-var-row-#{index}"}
              class="machine-row"
            >
              <.input
                name={"env_vars[#{index}][key]"}
                id={"env-var-key-#{index}"}
                label="Variable name"
                value={row.key}
                required
              />
              <.input
                name={"env_vars[#{index}][value]"}
                id={"env-var-value-#{index}"}
                label="Variable value"
                type="textarea"
                rows="2"
                value={row.value}
              />
              <button
                type="button"
                class="ghost"
                phx-click={
                  JS.dispatch("unsaved:dirty")
                  |> JS.push("remove-env-var", value: %{index: index}, target: @myself)
                }
                aria-label={"Remove variable #{index + 1}"}
              >Remove</button>
            </div>
            <button
              type="button"
              class="ghost"
              phx-click={JS.dispatch("unsaved:dirty") |> JS.push("add-env-var", target: @myself)}
              disabled={length(@variable_rows) >= 100}
            >Add variable</button>
          </fieldset>
        </section>
        <section id="machine-secrets" class="settings-part" aria-labelledby="machine-secrets-title">
          <h2 id="machine-secrets-title">Secrets</h2>
          <p class="settings-help">
            Values are never shown again. Environment secrets become machine environment variables. Vault secrets are inserted into outgoing requests and stay off the machine. The same key can exist in both.
          </p>
          <ul
            :if={@settings.env_keys != [] or @settings.vault_keys != []}
            id="secret-keys"
            class="secret-keys"
            aria-label="Secrets"
          >
            <li
              :for={
                {store, key} <-
                  Enum.map(@settings.env_keys, &{"env", &1}) ++
                    Enum.map(@settings.vault_keys, &{"vault", &1})
              }
              id={"secret-key-#{store}-#{key}"}
            >
              <code>{key}</code>
              <small>{MachineChanges.store_label(store)}</small>
              <span class="spacer"></span>
              <%= if Enum.any?(@secret_rows, &(&1.store == store and &1.key == key)) do %>
                <small class="secret-pending">
                  {if Enum.find(@secret_rows, &(&1.store == store and &1.key == key)).action ==
                        :remove,
                      do: "Removed on save",
                      else: "Replaced on save"}
                </small>
              <% else %>
                <button
                  :for={{action, label} <- [{"replace", "Replace"}, {"remove", "Remove"}]}
                  type="button"
                  class="ghost"
                  phx-click={
                    JS.dispatch("unsaved:dirty")
                    |> JS.push("change-secret",
                      value: %{store: store, key: key, action: action},
                      target: @myself
                    )
                  }
                  aria-label={"#{label} #{MachineChanges.store_label(store)} secret #{key}"}
                >{label}</button>
              <% end %>
            </li>
          </ul>
          <p :if={@settings.env_keys == [] and @settings.vault_keys == []} class="settings-help">
            No secrets yet.
          </p>
          <div :for={row <- @secret_rows} id={"secret-row-#{row.id}"} class="machine-row secret-row">
            <%= if row.existing do %>
              <p>
                <code>{row.key}</code>
                <small>{MachineChanges.store_label(row.store)}</small>
                {if row.action == :remove, do: " will be removed.", else: ""}
              </p>
            <% else %>
              <.input
                type="select"
                name={"secrets[#{row.id}][store]"}
                id={"secret-store-#{row.id}"}
                label="Store"
                value={row.store}
                options={[{"Environment", "env"}, {"Vault", "vault"}]}
              />
              <.input
                name={"secrets[#{row.id}][key]"}
                id={"secret-key-#{row.id}"}
                label="Secret name"
                value={row.key}
                autocomplete="off"
              />
            <% end %>
            <%!-- The value is the browser's alone: this is never drawn from
              the server, so a re-render cannot empty it or echo it. --%>
            <div
              :if={row.action == :set}
              id={"secret-value-field-#{row.id}"}
              class="field"
              phx-update="ignore"
            >
              <label for={"secret-value-#{row.id}"}>
                {if row.existing, do: "New value for #{row.key}", else: "Secret value"}
              </label>
              <input
                type="password"
                id={"secret-value-#{row.id}"}
                name={"secrets[#{row.id}][value]"}
                autocomplete="new-password"
              />
            </div>
            <button
              type="button"
              class="ghost"
              phx-click="drop-secret"
              phx-value-row={row.id}
              phx-target={@myself}
              aria-label={if row.existing, do: "Keep #{row.key}", else: "Remove this secret row"}
            >{if row.existing, do: "Undo", else: "Remove"}</button>
          </div>
          <button
            type="button"
            class="ghost"
            phx-click={JS.dispatch("unsaved:dirty") |> JS.push("add-secret", target: @myself)}
          >Add secret</button>
        </section>
        <section
          id="machine-run-script"
          class="settings-part"
          aria-labelledby="machine-run-script-title"
        >
          <h2 id="machine-run-script-title">Run script</h2>
          <p class="settings-help">
            The run script inherited by each track. Saving it stops tracks using this default; run them again to apply it. Leave the command blank for none.
          </p>
          <.input
            field={@defaults_form[:directory]}
            id="default-directory"
            label="App directory"
            aria-describedby="default-directory-help"
          />
          <p id="default-directory-help" class="settings-help">
            Relative path, such as apps/web. Use . for the repository root.
          </p>
          <.input
            field={@defaults_form[:command]}
            id="default-command"
            label="Run command"
            aria-describedby="default-command-help"
          />
          <p id="default-command-help" class="settings-help">
            Start the app on the assigned port and fail if it is occupied. For example: <code>npm run dev -- --host 0.0.0.0 --port "$PORT" --strictPort</code>.
          </p>
          <.input
            field={@defaults_form[:readiness_path]}
            id="default-readiness"
            label="Readiness path (optional)"
            aria-describedby="default-readiness-help"
          />
          <p id="default-readiness-help" class="settings-help">
            An HTTP path that responds when the app is ready, for example /health or /. Leave blank to run a process without a preview.
          </p>
          <.input
            field={@defaults_form[:stop_command]}
            id="default-stop-command"
            label="Stop command (optional)"
            aria-describedby="default-stop-command-help"
          />
          <p id="default-stop-command-help" class="settings-help">
            Runs in the same directory with the same $PORT. Leave blank to signal the process group. Stop always ends the managed service, even if this command fails.
          </p>
        </section>
        <div
          :if={@machine_review}
          id="machine-review"
          class="scrim"
          phx-remove={JS.focus(to: "#project-machine-bar [data-unsaved-save]")}
          phx-window-keydown="cancel-machine-review"
          phx-key="Escape"
          phx-target={@myself}
        >
          <div
            class="dialog machine-review"
            role="alertdialog"
            aria-modal="true"
            aria-labelledby="machine-review-title"
            aria-describedby="machine-review-body"
          >
            <div class="dialog-head">
              <h2 id="machine-review-title">
                {if @machine_review.rebuilds?,
                  do: "Save and rebuild the machine?",
                  else: "Save these changes?"}
              </h2>
            </div>
            <div id="machine-review-body" class="dialog-body">
              <ul class="machine-changes" aria-label="What changes">
                <li :for={line <- @machine_review.lines}>{line}</li>
              </ul>
              <p :if={@machine_review.rebuilds?} id="machine-review-closing">
                <strong>Rebuild closes {plural(@machine_review.count, "open track")}</strong>
                {if @machine_review.shared_only?,
                  do: "that share the project machine. Dedicated tracks are unaffected.",
                  else:
                    "visible to you, plus any private tracks you cannot see, and discards the machine's disk, including unpushed work."}
              </p>
              <p :if={not @machine_review.rebuilds? and @machine_review.rebuild?}>
                No project machine to rebuild: tracks opened from now on get these settings.
              </p>
              <p :if={not @machine_review.rebuild?}>
                The machine is not rebuilt. Tracks using the run script stop; run them again to apply it.
              </p>
            </div>
            <div class="dialog-foot">
              <button
                type="button"
                class="ghost"
                phx-click="cancel-machine-review"
                phx-target={@myself}
              >
                Cancel
              </button>
              <button
                type="submit"
                id="confirm-machine"
                name="machine_confirm"
                value="true"
                class={if @machine_review.rebuilds?, do: "danger", else: "primary"}
                phx-mounted={JS.focus()}
                disabled={MapSet.size(@pending) > 0}
              >
                {if @machine_review.rebuilds?, do: "Save & rebuild", else: "Save"}
              </button>
            </div>
          </div>
        </div>
      </form>
    </Settings.unsaved_changes>
    """
  end

  attr :project, :map, required: true
  attr :choices, :any, required: true
  attr :query, :string, required: true
  attr :change, :map, required: true
  attr :count, :any, required: true
  attr :pending, :any, required: true
  attr :myself, :any, required: true

  # RAV-76's dialog: 1. the repository, from the same list New track's
  # "Add a repository…" draws; 2. what happens; 3. the typed name.
  defp change_repository_dialog(assigns) do
    assigns =
      assign(assigns,
        repos:
          if(is_list(assigns.choices),
            do: Picker.filter_repos(assigns.choices, assigns.query),
            else: []
          ),
        picked: assigns.change["repo"],
        busy: MapSet.member?(assigns.pending, :change_repository),
        closing:
          if(is_integer(assigns.count),
            do: "#{plural(assigns.count, "open track")} will close",
            else: "Every open track will close"
          )
      )

    ~H"""
    <div
      id="change-repository-dialog"
      class="scrim"
      phx-remove={JS.focus(to: "#open-change-repository")}
      phx-window-keydown="cancel-change-repository"
      phx-key="Escape"
      phx-target={@myself}
    >
      <div
        class="dialog change-repository"
        role="dialog"
        aria-modal="true"
        aria-labelledby="change-repository-dialog-title"
        aria-describedby="change-repository-review"
      >
        <div class="dialog-head">
          <h2 id="change-repository-dialog-title">Change the repository of {@project.name}</h2>
        </div>
        <div class="dialog-body">
          <h3>1. Choose the repository</h3>
          <div id="change-repository-picker" class="repo-picker" data-jump-scope>
            <form
              id="change-repository-query-form"
              phx-change="filter-change-repository"
              phx-submit="filter-change-repository"
              phx-target={@myself}
            >
              <label for="change-repository-query">Filter repositories</label>
              <input
                id="change-repository-query"
                name="q"
                type="search"
                value={@query}
                placeholder="owner/repo"
                autocomplete="off"
                phx-debounce="100"
                phx-mounted={JS.focus()}
                data-jump-query
                aria-controls="change-repository-list"
                aria-describedby="change-repository-offer"
                disabled={@busy}
              />
            </form>
            <p id="change-repository-offer" class="settings-help">
              Only repositories the Ravix GitHub App can read are offered. To offer another, install the App on it first.
            </p>
            <p :if={@choices == :loading} class="hint" role="status">Loading repositories…</p>
            <RavixWeb.Live.RepoPicker.repositories
              :if={is_list(@choices)}
              id="change-repository-list"
              label="Repositories"
              repos={@repos}
              selected={@picked || ""}
              pick="pick-change-repository"
              target={@myself}
              busy={@busy}
              empty={
                if @choices == [],
                  do: "The Ravix GitHub App cannot read any other repository here.",
                  else: "No repository here matches."
              }
            />
          </div>
          <h3>2. What happens</h3>
          <p id="change-repository-review">
            The machine is rebuilt from {if @picked, do: @picked, else: "the new repository"}. <strong id="change-repository-closing">{@closing}</strong>, including private tracks you cannot see; their branches stay on GitHub, and unpushed work on the machine is lost. Settings, secrets, environment variables, members and history are kept.
          </p>
          <h3>3. Confirm</h3>
          <form
            id="change-repository-form"
            phx-change="edit-change-repository"
            phx-submit="change-repository"
            phx-target={@myself}
          >
            <.input
              name="confirm"
              id="change-repository-confirm"
              label={"Type #{@project.name} to confirm changing the repository"}
              value={@change["confirm"]}
              autocomplete="off"
              required
            />
            <div class="dialog-foot">
              <button
                type="button"
                class="ghost"
                phx-click="cancel-change-repository"
                phx-target={@myself}
                disabled={@busy}
              >
                Cancel
              </button>
              <button
                id="change-repository-submit"
                class="danger"
                disabled={
                  is_nil(@picked) or @change["confirm"] != @project.name or MapSet.size(@pending) > 0
                }
                phx-disable-with="Changing…"
              >
                Change repository
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  defp danger_zone(assigns) do
    ~H"""
    <section id="danger-zone" class="settings-danger" data-unsaved-ignore>
      <form
        :if={@orphan_count > 0}
        id="close-orphaned-private-form"
        phx-target={@myself}
        phx-submit="close-orphaned-private"
      >
        <h3>Close orphaned private tracks</h3>
        <p>{@orphan_count} private tracks with no remaining members</p>
        <p>
          Closing deletes their machines and uncommitted work. No track contents will be opened.
        </p>
        <.input
          name="confirm"
          id="close-orphaned-private-confirm"
          value=""
          label={"Type #{@project.name} to confirm closing orphaned tracks"}
          required
        />
        <button
          class="danger"
          disabled={MapSet.size(@pending) > 0}
          phx-disable-with="Closing…"
        >Close orphaned private tracks</button>
      </form>
      <p :if={Map.get(@settings, :shared_tracks) != nil}>
        Rebuild an individual track from that track; sibling tracks are unaffected.
        Deleting the project includes private tracks you cannot see and deletes all its tracks’ machines, uncommitted changes, unpushed commits, settings and secrets. Cleanup continues until deletion is confirmed.
      </p>
      <p :if={Map.get(@settings, :shared_tracks) == nil}>
        These actions also affect private tracks you cannot see. Rebuilding discards the machine’s disk and closes every track, keeping project settings and secrets for the next machine. Unpushed work on that disk is lost. Deleting also removes the project settings and secrets. These actions cannot be undone.
      </p>
      <section id="change-repository" aria-labelledby="change-repository-title">
        <h3 id="change-repository-title">Change repository</h3>
        <p id="change-repository-current">
          <%= if @project.repo do %>
            This project uses <code>{@project.repo}</code>.
          <% else %>
            This project has no repository yet.
          <% end %>
        </p>
        <p>
          Point the project at another repository the Ravix GitHub App can read. The machine is rebuilt from it and every open track closes; settings, secrets, members and history stay.
        </p>
        <button
          type="button"
          id="open-change-repository"
          class="ghost"
          phx-click="open-change-repository"
          phx-target={@myself}
          disabled={MapSet.size(@pending) > 0}
        >
          Change repository…
        </button>
        <.change_repository_dialog
          :if={@change_dialog}
          project={@project}
          choices={@repository_choices}
          query={@change_query}
          change={@change_repository}
          count={@change_count}
          pending={@pending}
          myself={@myself}
        />
      </section>
      <form
        :for={
          {action, label} <- [
            {"rebuild", "Rebuild machine and close all tracks"},
            {"delete", "Delete project"}
          ]
        }
        :if={action != "rebuild" or not Map.get(@settings, :default_only, false)}
        id={"project-#{action}-form"}
        phx-target={@myself}
        phx-change="confirm-danger"
        phx-submit="project-danger"
      >
        <h3>{label}</h3>
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
          disabled={Map.get(@confirmations, action) != @project.name or MapSet.size(@pending) > 0}
          phx-disable-with="Working…"
        >
          {if action == "rebuild", do: "Rebuild machine", else: label}
        </button>
      </form>
    </section>
    """
  end
end
