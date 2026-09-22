defmodule RavixWeb.Live.MachineDock do
  @moduledoc """
  The strip along the bottom of a track: a terminal, the preview's output,
  and the machine's metrics.

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
  alias Ravix.Vitals

  # The dock's three tabs, as the buttons spell them and as this module does.
  # `@labels` keeps the order the dock offers them in.
  @tabs %{"terminal" => :terminal, "run" => :run, "vitals" => :vitals}
  @labels [terminal: "Terminal", run: "Run", vitals: "Machine stats"]

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
    {:ok, socket |> assign(assigns) |> assign_new(:cwd, fn -> assigns.workdir end)}
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
       |> traced_async(:vitals, fn -> Vitals.report(user, id) end)}
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
       traced_async(socket, :exec, fn ->
         Terminal.exec(user, id, %{command: command, cwd: cwd})
       end)}
    end
  end

  def handle_event("clear", _, socket), do: {:noreply, assign(socket, output: [])}

  @impl true
  def handle_async(:vitals, {:ok, response}, socket),
    do: {:noreply, result(assign(socket, vitals_busy?: false), response, &assign(&1, vitals: &2))}

  def handle_async(:vitals, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(vitals_busy?: false)
       |> error({:unavailable, "The machine metrics did not arrive."})}

  def handle_async(:exec, {:ok, response}, socket) do
    {:noreply,
     result(assign(socket, exec_busy: false), response, fn s, output ->
       assign(s,
         cwd: output.cwd,
         output: List.update_at(s.assigns.output, -1, &Map.merge(&1, output))
       )
     end)}
  end

  def handle_async(:exec, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(exec_busy: false)
     |> error({:unavailable, "The command did not finish."})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
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
          hidden={@dock not in [:terminal, :run]}
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
          </div>
          <p :if={@dock == :run} class="hint">
            Run a command in this track’s worktree. For a persistent service, use Preview.
          </p>
          <p class="hint">
            Commands run without an interactive terminal. Use Preview for persistent servers.
          </p>
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
          <p :if={@vitals_busy?} role="status">Reading machine metrics…</p>
          <p :if={!@vitals_busy? && !@vitals}>No machine metrics available.</p>
          <p :if={@vitals && !@vitals.available}>Metrics unavailable: {@vitals.why}</p>
          <dl :if={@vitals && @vitals.readings}>
            <div :for={{label, value} <- Vitals.Readings.rows(@vitals.readings)}>
              <dt>{label}</dt>
              <dd>{value}</dd>
            </div>
          </dl>
        </div>
      </div>
    </div>
    """
  end
end
