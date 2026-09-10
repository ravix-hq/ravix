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

  @tabs ~w(terminal run vitals)

  @doc "The tabs the dock offers, in the order it offers them."
  @spec tabs() :: [String.t()]
  def tabs, do: @tabs

  # Two hundred commands of scrollback. A terminal that grows without bound
  # is a page that eventually stops rendering.
  @scrollback 200

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     if socket.assigns[:dock] do
       # `cwd` follows the track's worktree until a command answers from
       # somewhere else, so a re-render must not walk it back.
       socket
     else
       assign(socket,
         dock: "terminal",
         dock_open: false,
         output: [],
         exec_busy: false,
         cwd: assigns.workdir,
         vitals: nil
       )
     end}
  end

  @impl true
  def handle_event("dock", %{"name" => name}, socket) when name in @tabs do
    socket = assign(socket, dock: name, dock_open: true)

    if name == "vitals" do
      {:noreply,
       result(
         socket,
         Vitals.report(socket.assigns.current_user, socket.assigns.track_id),
         &assign(&1, vitals: &2)
       )}
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
       start_async(socket, :exec, fn -> Terminal.exec(user, id, %{command: command, cwd: cwd}) end)}
    end
  end

  def handle_event("clear", _, socket), do: {:noreply, assign(socket, output: [])}

  @impl true
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
          :for={name <- ~w(terminal run vitals)}
          class={if @dock == name, do: "selected", else: "ghost"}
          phx-click="dock"
          phx-target={@myself}
          phx-value-name={name}
        >
          {if name == "vitals", do: "Machine stats", else: String.capitalize(name)}
        </button>
      </nav>
      <div id="machine-dock" hidden={!@dock_open} class="machine-dock">
        <div
          hidden={@dock not in ["terminal", "run"]}
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
          <p :if={@dock == "run"} class="hint">
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
        <div :if={@dock == "vitals"} class="workspace-panel">
          <p :if={!@vitals}>No machine metrics available.</p>
          <p :if={@vitals && !@vitals.available}>Metrics unavailable: {@vitals.why}</p>
          <dl :if={@vitals && @vitals[:vitals]}>
            <div :for={{key, value} <- @vitals.vitals}>
              <dt>{key}</dt>
              <dd>{if is_map(value), do: Jason.encode!(value), else: to_string(value)}</dd>
            </div>
          </dl>
        </div>
      </div>
    </div>
    """
  end
end
