defmodule RavixWeb.Live.MachineDock do
  @moduledoc """
  The strip along the bottom of a track: standalone commands, interactive
  terminals, and the machine’s metrics.

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

  ## Terminals

  Each of this person's `Ravix.Terminal.Tab`s on the track is a tab here
  and a pane with the `Shell` hook in it (xterm.js). The pane asks to be
  attached once it has measured itself (`shell-attach`), which starts a
  `Ravix.Terminal.Shell` owned by this page's process; its messages arrive
  at `RavixWeb.TrackLive`, which hands them to `relay/3`. Keystrokes and
  resizes go to the page rather than to this component
  (`RavixWeb.TrackLive`'s `shell-input` and `shell-resize`), because every
  component event re-reads the session row and a keystroke should not cost
  a query: the page's own guard already stands in front of them, and the
  shell watches the session and the track itself.

  A reconnect remounts the page: the tabs are read again, each pane's hook
  asks to attach again, and the shell --- still running on the machine ---
  replays its output into it.
  """
  use RavixWeb, :live_component

  alias Ravix.Terminal
  alias Ravix.Terminal.Tab
  alias Ravix.Tracks
  alias Ravix.Tracks.MachineState
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
       machine: nil,
       vitals: nil,
       vitals_busy?: false,
       # This person's terminal tabs on the track, each with what the page
       # last heard about it. See `shell/2`.
       shells: [],
       # Whether this person may open a shell (Write, ADR 0010). Hiding the
       # button is courtesy; `Ravix.Terminal` refuses a Read member anyway.
       can_write: true
     )}
  end

  @doc """
  What a `Ravix.Terminal.Shell` said, applied to the page.

  Called by `RavixWeb.TrackLive` for `{:terminal, tab_id, event}`, after the
  page's own guard has let the message through. Output goes straight to the
  pane's hook as an event --- it is not state, and re-rendering the dock for
  every packet would be the whole dock for every packet. Anything that
  changes what the tab says goes to this component.
  """
  @spec relay(Phoenix.LiveView.Socket.t(), String.t(), term()) :: Phoenix.LiveView.Socket.t()
  def relay(socket, tab_id, {:data, bytes}) when is_binary(bytes),
    do: push_event(socket, "shell:output", %{id: tab_id, data: Base.encode64(bytes)})

  def relay(socket, tab_id, event) do
    send_update(__MODULE__, id: "machine-dock-panel", shell_event: {tab_id, event})

    # A fresh attachment replays the shell's output from the start, so the
    # pane clears first rather than drawing it twice.
    if event == :ready, do: push_event(socket, "shell:reset", %{id: tab_id}), else: socket
  end

  @impl true
  def update(%{shell_event: {tab_id, event}}, socket),
    do: {:ok, shell_event(socket, tab_id, event)}

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
        |> load_shells()
        |> scoped_async(:machine_status, fn ->
          Terminal.status(user, id, passive: true)
        end)
      else
        socket
      end

    {:ok, socket}
  end

  # The tabs of the track now shown. Whatever this page had attached belonged
  # to the track it was showing before --- or to access it no longer has ---
  # so it is let go first: the shells go on running for their next page.
  defp load_shells(socket) do
    Enum.each(socket.assigns.shells, &Terminal.detach(&1.tab.id))

    shells =
      with true <- connected?(socket),
           {:ok, tabs} <- Terminal.tabs(socket.assigns.current_user, socket.assigns.track_id) do
        Enum.map(tabs, &%{tab: &1, status: :connecting})
      else
        _ -> []
      end

    dock =
      case socket.assigns.dock do
        {:shell, id} ->
          if Enum.any?(shells, &(&1.tab.id == id)), do: {:shell, id}, else: :terminal

        dock ->
          dock
      end

    assign(socket, shells: shells, dock: dock)
  end

  defp shell_event(socket, tab_id, :ready), do: put_status(socket, tab_id, :ready)

  defp shell_event(socket, tab_id, :disconnected),
    do: put_status(socket, tab_id, :disconnected)

  defp shell_event(socket, tab_id, {:exited, code}),
    do: put_status(socket, tab_id, {:ended, "The shell exited (#{code})."})

  defp shell_event(socket, tab_id, {:ended, :revoked}),
    do: put_status(socket, tab_id, {:ended, "This terminal ended because your access did."})

  defp shell_event(socket, tab_id, {:ended, :lost}),
    do:
      put_status(
        socket,
        tab_id,
        {:ended, "This terminal ended while nobody was attached to it."}
      )

  defp shell_event(socket, tab_id, {:ended, reason}),
    do: put_status(socket, tab_id, {:ended, RavixWeb.Error.from(reason).message})

  defp shell_event(socket, _tab_id, _event), do: socket

  defp put_status(socket, tab_id, status) do
    update(socket, :shells, fn shells ->
      Enum.map(shells, fn
        %{tab: %{id: ^tab_id}} = shell -> %{shell | status: status}
        shell -> shell
      end)
    end)
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

  def handle_event("shell", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.shells, &(&1.tab.id == id)),
      do: {:noreply, assign(socket, dock: {:shell, id}, dock_open: true)},
      else: {:noreply, socket}
  end

  def handle_event("shell-new", _, socket) do
    %{current_user: user, track_id: id} = socket.assigns

    {:noreply,
     result(socket, Terminal.open_tab(user, id), fn s, tab ->
       s
       |> update(:shells, &(&1 ++ [%{tab: tab, status: :connecting}]))
       |> assign(dock: {:shell, tab.id}, dock_open: true)
     end)}
  end

  # The pane has measured itself: attach it. A pane that asks again --- the
  # page reconnected, or somebody pressed Reconnect --- gets the attachment it
  # already has, or a fresh one that re-attaches to the running shell.
  def handle_event("shell-attach", %{"id" => id} = params, socket) do
    case Enum.find(socket.assigns.shells, &(&1.tab.id == id)) do
      %{status: {:ended, _}} ->
        {:noreply, socket}

      %{} ->
        %{current_user: user, session_hash: hash, track_id: track_id} = socket.assigns
        size = %{cols: params["cols"], rows: params["rows"]}

        # A reconnect remounts this component with the dock closed; the pane
        # that was in front before it says so, and is put back.
        socket =
          if params["select"] == true,
            do: assign(socket, dock: {:shell, id}, dock_open: true),
            else: socket

        case Terminal.attach(user, hash, track_id, id, size) do
          {:ok, _shell} -> {:noreply, put_status(socket, id, :connecting)}
          {:error, reason} -> {:noreply, shell_event(socket, id, {:ended, reason})}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("shell-close", %{"id" => id}, socket) do
    %{current_user: user, track_id: track_id} = socket.assigns
    Terminal.detach(id)

    # Whether or not it was still there to close, it is not this page's any more.
    _ = Terminal.close_tab(user, track_id, id)
    shells = Enum.reject(socket.assigns.shells, &(&1.tab.id == id))

    dock =
      if socket.assigns.dock == {:shell, id},
        do: shells |> List.last() |> then(&if(&1, do: {:shell, &1.tab.id}, else: :terminal)),
        else: socket.assigns.dock

    {:noreply, assign(socket, shells: shells, dock: dock)}
  end

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
    do: {:noreply, assign(socket, machine_status: :unavailable)}

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
    do: "Machine stats are unavailable because the machine connection is not configured."

  defp vitals_reason(%Vitals.Report{why: :no_machine}),
    do: "No machine is available yet."

  defp vitals_reason(%Vitals.Report{why: why}) when why in [:no_sprite, :unreachable],
    do: "The machine is asleep or unreachable. It wakes on the next turn."

  # Asking again cannot conjure a token this server was not given.
  defp retry_vitals?(%Vitals.Report{why: :no_token}), do: false
  defp retry_vitals?(_), do: true

  # Whose machine this is matters as much as its state: a shared track's
  # terminal and files are the whole project's machine, a dedicated one's are not.
  defp machine_label({:ok, {_, :dedicated, _, _}}), do: "This track's machine"

  defp machine_label({:ok, {_, :shared, _, _}}),
    do: "Shared project machine (used by all of this project's tracks)"

  defp machine_label(_), do: "Machine"

  defp shell_status(:connecting), do: "Connecting to the machine…"

  defp shell_status(:disconnected),
    do: "The connection to this terminal dropped. Its shell may still be running."

  defp shell_status({:ended, message}), do: message
  defp shell_status(_ready), do: nil

  # The status line, in the words the header chip and the sidebar use
  # (`Ravix.Tracks.MachineState`), qualified only where the terminal's own
  # probe knows something the track does not: that this deployment cannot
  # reach machines at all, or that there is no machine yet.
  defp machine_status(%Terminal.Status{why: :no_machine}, _machine),
    do: "No machine is available yet."

  defp machine_status(%Terminal.Status{why: :no_token}, _machine),
    do: "Machine status is unavailable because the machine connection is not configured."

  defp machine_status(%Terminal.Status{why: why}, %{state: :idle})
       when why in [:no_sprite, :unreachable],
       do: "Idle. The machine did not answer just now; your next message wakes it."

  # The probe itself failed: that says nothing about the machine.
  defp machine_status(:unavailable, _machine),
    do: "Machine status is unavailable. Try again later."

  # The probe found it running, so a stale Asleep (the row is cleared on the
  # way) must not say otherwise.
  defp machine_status(%Terminal.Status{available: true}, %{state: :asleep}), do: "Idle."

  defp machine_status(_status, nil), do: "Checking machine status…"
  defp machine_status(_status, %{state: state, detail: nil}), do: "#{MachineState.label(state)}."

  defp machine_status(_status, %{state: state, detail: detail}),
    do: "#{MachineState.label(state)}. #{detail}"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="machine-dock-host">
      <p id="track-machine-label">{machine_label(@machine_identity)}</p>
      <p id="track-machine-status" role="status">
        {machine_status(@machine_status, @machine)}
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
        <span :for={shell <- @shells} class="dock-shell-tab" data-shell-tab={shell.tab.id}>
          <button
            class={if @dock == {:shell, shell.tab.id}, do: "selected", else: "ghost"}
            phx-click="shell"
            phx-target={@myself}
            phx-value-id={shell.tab.id}
          >
            <.icon name="terminal" size={12} />
            {Tab.label(shell.tab)}
          </button>
          <button
            class="ghost dock-shell-close"
            phx-click="shell-close"
            phx-target={@myself}
            phx-value-id={shell.tab.id}
            aria-label={"Close " <> Tab.label(shell.tab)}
            title={"Close " <> Tab.label(shell.tab)}
          >
            <.icon name="x" size={11} />
          </button>
        </span>
        <button
          :if={@can_write}
          id="dock-shell-new"
          class="ghost dock-shell-new"
          phx-click="shell-new"
          phx-target={@myself}
          disabled={length(@shells) >= Terminal.max_tabs()}
          aria-label="New terminal"
          title={
            if length(@shells) >= Terminal.max_tabs(),
              do: "A track can have #{Terminal.max_tabs()} terminals open at once",
              else: "New terminal"
          }
        >
          <.icon name="plus" size={13} />
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
          <p id="terminal-machine-label">{machine_label(@machine_identity)}</p>
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
                Each command runs on its own. For an interactive shell, such as
                a console or a REPL, open a terminal with +.
                For a process that keeps running, use the track’s run script.
                <:action label="Open Preview" click={JS.push("panel", value: %{name: "preview"})} />
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
        <div
          :for={shell <- @shells}
          id={"shell-pane-" <> shell.tab.id}
          hidden={@dock != {:shell, shell.tab.id}}
          class="term workspace-terminal shell-pane"
        >
          <div :if={shell_status(shell.status)} class="shell-status" role="status">
            <span>{shell_status(shell.status)}</span>
            <button
              :if={shell.status == :disconnected}
              class="ghost"
              phx-click={JS.dispatch("ravix:shell-reattach", to: "#shell-" <> shell.tab.id)}
            >
              Reconnect
            </button>
            <button
              :if={match?({:ended, _}, shell.status)}
              class="ghost"
              phx-click="shell-close"
              phx-target={@myself}
              phx-value-id={shell.tab.id}
            >
              Close tab
            </button>
          </div>
          <div
            id={"shell-" <> shell.tab.id}
            class="shell-screen"
            phx-hook="Shell"
            phx-update="ignore"
            phx-target={@myself}
            data-id={shell.tab.id}
            data-label={Tab.label(shell.tab)}
            data-xterm-js={~p"/assets/js/xterm.js"}
            data-xterm-css={~p"/assets/js/xterm.css"}
          >
          </div>
        </div>
        <div :if={@dock == :vitals} class="workspace-panel">
          <p id="vitals-machine-label">{machine_label(@machine_identity)}</p>
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
