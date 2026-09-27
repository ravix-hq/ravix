defmodule RavixWeb.Live.MachineDock do
  @moduledoc """
  The strip along the bottom of a track: standalone commands and the machine’s metrics.

  Its own `live_component` because every piece of state it needs is state
  nothing else on the page reads -- which tab is showing, whether the strip
  is open, the two hundred lines of scrollback, the working directory the
  last command answered from, and whether one is running. `RavixWeb.TrackLive`
  carried all six as top-level assigns, and it had thirty-two of them.

  The scrollback is the reason this is a component rather than a function
  component: a command's output arrives asynchronously and appends to a list
  that only this strip renders. Keeping it here means a slow `ls` re-renders
  the dock and not the transcript beside it.

  Running a command goes through `Ravix.Terminal.exec/3`, which takes the
  signed-in user and establishes track access before it reaches the machine.
  Passing `current_user` in rather than reading it from the parent's assigns
  is what keeps that true: the component asks with the same person the page
  was mounted for.
  """
  use RavixWeb, :live_component

  alias Ravix.Terminal
  alias Ravix.Tracks
  alias Ravix.Vitals
  alias RavixWeb.Live.Hooks

  # The dock's tabs, as the buttons spell them and as this module does.
  # `@labels` keeps the order the dock offers them in.
  @tabs %{"terminal" => :terminal, "vitals" => :vitals}
  @labels [terminal: "Commands", vitals: "Machine stats"]

  @doc "The tabs the dock offers, labelled, in the order it offers them."
  @spec tabs() :: [{atom(), String.t()}]
  def tabs, do: @labels

  # Two hundred commands of scrollback. A terminal that grows without bound
  # is a page that eventually stops rendering.
  @scrollback 200

  # `mount/1` runs exactly once per component instance, before the first
  # `update/2`. What stood here was `if socket.assigns[:dock]`, which is that
  # once-only callback written as a sentinel key --- and a sentinel spelled
  # through `assigns[...]` rather than `assigns...` is one that answers nil
  # for a misspelling, so the defaults would be re-applied on every parent
  # re-render and the strip would close itself while somebody was reading it.
  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       dock: :terminal,
       dock_open: false,
       output: [],
       exec_busy: false,
       machine_status: nil,
       vitals: nil,
       vitals_busy?: false
     )}
  end

  @impl true
  def update(assigns, socket) do
    # `cwd` cannot be one of those: it is seeded from the track's worktree,
    # which arrives with the parent's assigns and so does not exist yet in
    # `mount/1`. It follows the worktree only until a command answers from
    # somewhere else, and `assign_new/3` is the framework's way of saying
    # exactly that --- seed it the first time, never walk it back after.
    socket = assign(socket, assigns)
    identity = Tracks.machine_identity(socket.assigns.current_user, socket.assigns.track_id)
    changed? = socket.assigns[:machine_identity] != identity
    socket = assign(socket, machine_identity: identity)

    socket =
      if changed? do
        %{current_user: user, track_id: id} = socket.assigns

        socket
        |> assign(
          cwd: socket.assigns.workdir,
          output: [],
          vitals: nil,
          machine_status: nil,
          exec_busy: false
        )
        |> scoped_async(:machine_status, fn ->
          Terminal.status(user, id, passive: true)
        end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("dock", %{"name" => name}, socket) when is_map_key(@tabs, name) do
    socket = assign(socket, dock: Map.fetch!(@tabs, name), dock_open: true)

    # A `live_component` runs in its parent's process, so reading the metrics
    # here stopped the whole track page --- the transcript included --- for as
    # long as the machine took to answer. The strip says it is reading and the
    # page carries on.
    if socket.assigns.dock == :vitals do
      %{current_user: user, track_id: id} = socket.assigns

      {:noreply,
       socket
       |> assign(vitals: nil, vitals_busy?: true)
       |> scoped_async(:vitals, fn -> Vitals.report(user, id) end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle-dock", _, socket),
    do: {:noreply, assign(socket, dock_open: !socket.assigns.dock_open)}

  def handle_event("exec", %{"command" => command}, socket) do
    if socket.assigns.exec_busy do
      # A second Enter while one is running is not a second command.
      {:noreply, socket}
    else
      %{current_user: user, track_id: id, cwd: cwd} = socket.assigns

      socket =
        assign(socket,
          exec_busy: true,
          output:
            Enum.take(
              socket.assigns.output ++ [%{command: command, stdout: "", stderr: "", code: nil}],
              -@scrollback
            )
        )

      {:noreply,
       scoped_async(socket, :exec, fn ->
         Terminal.exec(user, id, %{command: command, cwd: cwd})
       end)}
    end
  end

  def handle_event("clear", _, socket), do: {:noreply, assign(socket, output: [])}

  # Component async callbacks do not pass through the parent's hooks. Check
  # the session, membership and generation again before rendering any output.
  @impl true
  def handle_async(name, response, socket) do
    Hooks.component(socket, fn ->
      current = Tracks.machine_identity(socket.assigns.current_user, socket.assigns.track_id)

      case response do
        {:ok, {identity, result}} when identity == current and elem(current, 0) == :ok ->
          receive_async(name, {:ok, result}, socket)

        {:exit, reason} ->
          receive_async(name, {:exit, reason}, socket)

        _ ->
          {:noreply,
           assign(socket,
             exec_busy: false,
             vitals_busy?: false,
             output: [],
             vitals: nil,
             machine_status: nil
           )}
      end
    end)
  end

  defp scoped_async(socket, name, fun) do
    %{current_user: user, track_id: id} = socket.assigns

    traced_async(socket, name, fn ->
      identity = Tracks.machine_identity(user, id)
      {identity, if(elem(identity, 0) == :ok, do: fun.(), else: {:error, :not_found})}
    end)
  end

  defp receive_async(:machine_status, {:ok, {:ok, status}}, socket),
    do: {:noreply, assign(socket, machine_status: status)}

  defp receive_async(:machine_status, _, socket),
    do: {:noreply, assign(socket, machine_status: nil)}

  defp receive_async(:vitals, {:ok, response}, socket),
    do: {:noreply, result(assign(socket, vitals_busy?: false), response, &assign(&1, vitals: &2))}

  defp receive_async(:vitals, {:exit, reason}, socket),
    do: {:noreply, socket |> assign(vitals_busy?: false) |> exit(reason)}

  defp receive_async(:exec, {:ok, response}, socket) do
    {:noreply,
     result(assign(socket, exec_busy: false), response, fn s, output ->
       assign(s,
         cwd: output.cwd,
         output: List.update_at(s.assigns.output, -1, &Map.merge(&1, output))
       )
     end)}
  end

  defp receive_async(:exec, {:exit, reason}, socket),
    do: {:noreply, socket |> assign(exec_busy: false) |> exit(reason)}

  # Why there is nothing to show, in words. `Vitals` answers with an atom so
  # that nothing past it has to parse a sentence; this is where the atom
  # becomes one, rather than being printed as `no_machine`.
  defp vitals_reason(nil), do: "The machine did not answer this time."

  defp vitals_reason(%Vitals.Report{available: true}),
    do: "The machine answered but reported no readings."

  defp vitals_reason(%Vitals.Report{why: :no_token}),
    do: "This server has no Sprites token, so it cannot read machine stats."

  defp vitals_reason(%Vitals.Report{why: :no_machine}),
    do: "This project has no machine yet. One is built when a track first needs it."

  defp vitals_reason(%Vitals.Report{why: why}) when why in [:no_sprite, :unreachable],
    do: "The machine is asleep or unreachable. It wakes on the next turn."

  # Asking again cannot conjure a token this server was not given.
  defp retry_vitals?(%Vitals.Report{why: :no_token}), do: false
  defp retry_vitals?(_), do: true

  # Whose machine this is matters as much as its state: a shared track's
  # terminal and files are the whole project's machine, a dedicated one's are not.
  defp machine_status(status, {:ok, {_id, :dedicated, _sandbox, _generation}}),
    do: machine_state(status, "This track’s machine")

  defp machine_status(status, _identity),
    do: machine_state(status, "The shared project machine") <> shared_note(status)

  defp machine_state(nil, whose), do: "Checking " <> lowercase_first(whose) <> "…"
  defp machine_state(%Terminal.Status{available: true}, whose), do: whose <> " is running"

  defp machine_state(%Terminal.Status{why: :no_machine}, _whose),
    do: "This track has no machine yet"

  defp machine_state(%Terminal.Status{why: :no_token}, _whose),
    do: "Machine status is unavailable"

  defp machine_state(_status, whose), do: whose <> " is asleep or unreachable"

  defp shared_note(%Terminal.Status{why: why}) when why in [:no_machine, :no_token], do: ""
  defp shared_note(_status), do: " (used by all of this project’s tracks)"

  defp lowercase_first(<<first::utf8, rest::binary>>),
    do: String.downcase(<<first::utf8>>) <> rest

  @impl true
  def render(assigns) do
    ~H"""
    <div class="machine-dock-host">
      <p id="track-machine-status" role="status">
        {machine_status(@machine_status, @machine_identity)}
      </p>
      <nav class="workspace-tabs dock-tabs" aria-label="Machine panels">
        <button
          class="ghost dock-toggle"
          phx-click="toggle-dock"
          phx-target={@myself}
          aria-expanded={to_string(@dock_open)}
          aria-controls="machine-dock"
          aria-label={if @dock_open, do: "Collapse the dock", else: "Expand the dock"}
        >
          <.icon name="chevron" size={13} open={@dock_open} />
        </button>
        <button
          :for={{tab, label} <- tabs()}
          class={if @dock == tab, do: "selected", else: "ghost"}
          phx-click="dock"
          phx-target={@myself}
          phx-value-name={tab}
        >
          {label}
        </button>
      </nav>
      <div id="machine-dock" hidden={!@dock_open} class="machine-dock">
        <div
          hidden={@dock != :terminal}
          id="track-terminal"
          phx-hook="Terminal"
          phx-target={@myself}
          class="term workspace-terminal"
        >
          <div class="term-scroll" data-terminal-output>
            <div :for={block <- @output}>
              <strong>$ {block.command}</strong><pre>{block.stdout}</pre><pre class="error">{block.stderr}</pre>
              <span :if={block.code && block.code != 0}>
                Exit {block.code}
              </span>
            </div>
            <div :if={@output == [] && @dock == :terminal} class="dock-empty">
              <.empty icon="terminal" title="No commands yet">
                Run commands, tests, builds and scripts in this track’s worktree.
                Each command runs on its own, without an interactive terminal.
                For a server that keeps running, start a preview instead.
                <:action label="Open Previews" click={JS.push("panel", value: %{name: "preview"})} />
              </.empty>
            </div>
          </div>
          <div class="term-input">
            <span class="ps1">{if @cwd, do: Path.basename(@cwd), else: ""} $</span>
            <fieldset class="term-command" disabled={@exec_busy}>
              <div id="terminal-command" phx-update="ignore">
                <input data-terminal-input aria-label="Command" />
              </div>
            </fieldset>
            <button class="ghost" phx-click="clear" phx-target={@myself}>
              Clear
            </button>
          </div>
        </div>
        <div :if={@dock == :vitals} class="workspace-panel">
          <.loading_status :if={@vitals_busy?}>Reading machine metrics…</.loading_status>
          <div :if={!@vitals_busy? && !(@vitals && @vitals.readings)} class="dock-empty">
            <.empty icon="machine" title="No machine stats" because={vitals_reason(@vitals)}>
              CPU, memory and disk for the machine this track runs on.
              <:action
                :if={retry_vitals?(@vitals)}
                label="Try again"
                click={JS.push("dock", target: @myself, value: %{name: "vitals"})}
              />
            </.empty>
          </div>
          <dl :if={@vitals && @vitals.readings} class="machine-stats">
            <div :for={{label, value, fraction} <- RavixWeb.MachineStats.rows(@vitals.readings)}>
              <dt>{label}</dt>
              <dd>
                <span>{value}</span>
                <meter :if={!is_nil(fraction)} min="0" max="1" value={fraction} aria-label={label}>
                  {RavixWeb.MachineStats.percent(fraction)}
                </meter>
              </dd>
            </div>
          </dl>
        </div>
      </div>
    </div>
    """
  end
end
