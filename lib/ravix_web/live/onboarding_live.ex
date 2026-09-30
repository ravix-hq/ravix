defmodule RavixWeb.OnboardingLive do
  @moduledoc """
  The first visit: what Ravix is, then the three things a first project needs.

  Four steps, each its own URL so that the back button, a reload and the round
  trip to GitHub all land somewhere sensible:

      /welcome            how the app works
      /welcome/agent      connect Claude Code or Codex
      /welcome/github     install the GitHub App on the repositories to work in
      /welcome/project    what to work on, and where: the project, its first
                          track and that track's first prompt, in one Start

  ## Nothing here is a gate

  `RavixWeb.WorkspaceLive` sends somebody here when they have no project and
  have never finished or dismissed this, and that is the only push. Every step
  can be skipped, because each has a legitimate reason to be: somebody invited
  to a teammate's project runs on *that* person's subscription and needs none of
  their own, and a scratch project needs no repository. What a step does is
  done by the same context call the rest of the app uses ---
  `Ravix.Accounts.Inference.connect/2`, `Ravix.Projects.create/2`,
  `Ravix.Tracks.open/3` --- so skipping one leaves nothing half-made that the
  workspace cannot finish later. Skipping lands on `/home`, whose empty state
  is the same first-prompt form as the last step here.

  ## Where somebody resumes

  Installing the GitHub App leaves the site and comes back through
  `/?installed=1`, which the workspace turns into `/welcome` again. `/welcome`
  itself is therefore the one URL that decides: it shows the introduction to
  somebody who has connected nothing, and goes straight to the first step still
  undone for somebody who has. The progress is read from what exists (a
  credential on the person, an installation on GitHub) rather than from a
  "current step" column, which would be a second account of the same facts.

  ## The agent step

  Is `RavixWeb.Live.AgentPanel`, which the workspace's account dialog also
  renders, so the walkthrough and the place somebody comes back to weeks
  later cannot drift. Here it is compact: a card per agent, Connect or
  Connected, and the rest behind Manage. What the page keeps is what a
  component cannot do: hand the panel its polling tick and offer Continue
  once something is connected.

  ## The last step

  Is `RavixWeb.Live.QuickStart`: a repository, "What do you want to work
  on?", and Start. Start creates the project, opens its first track with the
  prompt queued on it, and lands in that track, where the prompt waits for
  setup. The agent is the default the agent step left, shown as a chip.
  """
  use RavixWeb, :live_view

  alias Ravix.{Accounts, Projects}
  alias Ravix.Accounts.{Access, Inference, User}
  alias Ravix.Workspaces.{Installation, Repositories}
  alias RavixWeb.Live.{AgentPanel, Guard, QuickStart}

  @steps [:intro, :agent, :github, :project]
  @paths %{
    intro: "/welcome",
    agent: "/welcome/agent",
    github: "/welcome/github",
    project: "/welcome/project"
  }

  @doc "The steps, in order, with the path each lives at."
  @spec steps() :: [{atom(), String.t()}]
  def steps, do: Enum.map(@steps, &{&1, @paths[&1]})

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       github_available: Accounts.capabilities().github,
       quick_form: nil,
       quick_busy: false,
       # `nil` until GitHub has answered, which is not the same as "none": the
       # GitHub step says "checking" for the first and offers the install
       # button for the second.
       installations: nil,
       installation: nil,
       repos: [],
       repos_loading: false,
       workspace_github: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> validate_session()
      |> assign(page_title: step_title(socket.assigns.live_action) <> " · Ravix")

    cond do
      is_nil(socket.assigns.current_user) ->
        {:noreply, push_navigate(socket, to: "/login")}

      # Back from GitHub, or back tomorrow: carry on from the first step still
      # undone rather than from the top.
      socket.assigns.live_action == :intro and params["from"] != "start" and
          Inference.connected?(socket.assigns.current_user) ->
        {:noreply, push_patch(socket, to: @paths[:github])}

      true ->
        {:noreply, enter(socket, socket.assigns.live_action)}
    end
  end

  defp step_title(:intro), do: "Welcome"
  defp step_title(:agent), do: "Connect your agent"
  defp step_title(:github), do: "Connect GitHub"
  defp step_title(:project), do: "Start your first track"

  # The two steps that read GitHub do it on arrival and off this process.
  defp enter(socket, :project), do: socket |> QuickStart.init() |> load_repos(nil) |> preselect()

  defp enter(socket, step) when step == :github,
    do: socket |> load_repos(nil) |> workspace_github()

  defp enter(socket, _step), do: socket

  # A URL patch is not a message, so no hook has run for it. See the same
  # function in `RavixWeb.WorkspaceLive`.
  defp validate_session(%{assigns: %{current_user: nil}} = socket), do: socket

  defp validate_session(socket) do
    case Guard.verify(socket.assigns[:session_guard], socket.assigns.session_hash) do
      {:ok, guard} -> assign(socket, session_guard: guard)
      :error -> assign(socket, current_user: nil)
    end
  end

  @impl true
  def handle_event("installation", %{"installation" => id}, socket) do
    case Integer.parse(id) do
      {id, ""} -> {:noreply, load_repos(socket, id)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("quick-start-edit", %{"quick_start" => params}, socket),
    do: {:noreply, QuickStart.edit(socket, params)}

  def handle_event("quick-start-suggest", %{"prompt" => prompt}, socket),
    do: {:noreply, QuickStart.suggest(socket, prompt)}

  # Only the step that draws the form takes it: a stale page on another step
  # has no repositories read for it to check against.
  def handle_event("quick-start", %{"quick_start" => params}, socket)
      when socket.assigns.live_action == :project do
    user = socket.assigns.current_user

    {:noreply,
     QuickStart.submit(
       socket,
       params,
       targets(socket.assigns.repos),
       socket.assigns.repos,
       fn target, prompt, runtime ->
         QuickStart.run(user, target, prompt, runtime)
       end
     )}
  end

  def handle_event("quick-start", _params, socket), do: {:noreply, socket}

  # Leaving without finishing is finishing: the workspace must not send
  # somebody back here every time they open it.
  def handle_event("skip", _params, socket) do
    {:noreply, socket |> finish() |> push_navigate(to: "/home")}
  end

  @impl true
  # The agent panel's clock; see `RavixWeb.Live.AgentPanel`.
  def handle_info({:agent_panel, id, tick}, socket) do
    if id == "agent-panel" and socket.assigns.live_action == :agent,
      do: send_update(AgentPanel, id: id, tick: tick)

    {:noreply, socket}
  end

  # The cards say Connected, and Continue appears; the step is not left for
  # them, because a second agent is one more card away.
  def handle_info({:agent_connected, %User{} = user, _agent}, socket),
    do: {:noreply, assign(socket, current_user: user)}

  def handle_info({:agent_default_changed, %User{} = user}, socket),
    do: {:noreply, assign(socket, current_user: user)}

  # The panel removed something. The step is not done by that; it stays.
  def handle_info({:agent_disconnected, %User{} = user, _agent}, socket),
    do: {:noreply, assign(socket, current_user: user)}

  # The panel cannot put a flash in the page's own socket; see
  # `RavixWeb.Live.Result.flash/3`. The clear is its timer for a notice.
  def handle_info({:flash, kind, message}, socket),
    do: {:noreply, flash(socket, kind, message)}

  def handle_info({:clear_flash, kind, message}, socket),
    do: {:noreply, clear_notice(socket, kind, message)}

  @impl true
  # Straight into the track: its setup steps and the prompt waiting for them
  # are what somebody who pressed Start came to see. A project whose track
  # could not open is still somewhere to be, with the reason said there.
  def handle_async(:quick_start, {:ok, response}, socket) do
    {:noreply,
     result(
       assign(socket, quick_busy: false),
       response,
       fn
         s, %{project: project, track: nil, error: reason} ->
           s
           |> finish()
           |> error(reason)
           |> push_navigate(to: "/p/#{project.id}")

         s, %{project: project, track: track, queued: queued} ->
           s = finish(s)
           s = if message = QuickStart.refused(queued), do: flash(s, :error, message), else: s
           push_navigate(s, to: "/p/#{project.id}/t/#{track.id}")
       end,
       :quick_form
     )}
  end

  def handle_async(:repos, {:ok, {:ok, data}}, socket) do
    {:noreply,
     socket
     |> assign(
       repos_loading: false,
       repos: data.repos,
       installations: data.installations,
       installation: data.selected
     )
     |> preselect()}
  end

  # GitHub could not be read. "None" is the honest thing to draw: the install
  # button is also how somebody whose token has gone gets a working one.
  def handle_async(:repos, _other, socket),
    do:
      {:noreply,
       assign(socket, repos_loading: false, repos: [], installations: [], installation: nil)}

  def handle_async(_name, {:exit, reason}, socket),
    do: {:noreply, socket |> assign(quick_busy: false) |> exit(reason)}

  defp finish(socket) do
    case Accounts.finish_onboarding(socket.assigns.current_user) do
      {:ok, user} -> assign(socket, current_user: user)
      {:error, _changeset} -> socket
    end
  end

  # What is on offer is cleared first, for the reason
  # `RavixWeb.WorkspaceLive.load_repos/2` gives: the previous answer belongs to
  # whichever installation was selected last.
  defp load_repos(socket, id) do
    if socket.assigns.github_available do
      user = socket.assigns.current_user

      socket
      |> assign(repos_loading: true, repos: [], installation: nil)
      |> traced_async(:repos, fn -> Projects.repos(user, id) end)
    else
      assign(socket, repos_loading: false, repos: [], installations: [], installation: nil)
    end
  end

  # RAV-69: which of the person's GitHub accounts their current workspace
  # uses, from the same cached catalog the workspace page reads, so the two
  # say the same thing. Nil with workspaces off or none current.
  defp workspace_github(socket) do
    user = socket.assigns.current_user

    with {:ok, %{workspace: workspace, role: role}} <- Ravix.Workspaces.current(user),
         {:ok, catalog} <- Repositories.catalog(user, workspace.id) do
      connected =
        for installation <- catalog.installations,
            Installation.status(installation) == :active,
            into: MapSet.new(),
            do: installation.installation_id

      assign(socket,
        workspace_github: %{
          workspace: workspace,
          owner?: Access.can?(role, :add_installations),
          connected: connected
        }
      )
    else
      _ -> assign(socket, workspace_github: nil)
    end
  end

  # One pair or none, for the template's `:for`.
  defp in_workspace(installations, %{connected: connected}),
    do: [Enum.split_with(installations, &MapSet.member?(connected, &1.id))]

  defp in_workspace(_installations, nil), do: []

  defp handles(installations), do: Enum.map_join(installations, ", ", &"@#{&1.account}")

  # The only repository GitHub shows is the one somebody means; with more,
  # choosing is theirs. Nothing chosen already is overridden.
  defp preselect(
         %{assigns: %{live_action: :project, repos_loading: false, quick_form: %{} = form}} =
           socket
       ) do
    case {form.params["target"], QuickStart.preselect(targets(socket.assigns.repos))} do
      {blank, value} when blank in [nil, ""] and is_binary(value) ->
        QuickStart.edit(socket, %{"target" => value})

      _ ->
        socket
    end
  end

  defp preselect(socket), do: socket

  # ── what the template asks ───────────────────────────────────────────

  # Somebody here has no project of their own yet, or chose to come back
  # here; either way a repository is what they are choosing.
  defp targets(repos), do: QuickStart.targets(repos)

  defp path(step), do: Map.fetch!(@paths, step)

  defp position(step), do: Enum.find_index(@steps, &(&1 == step)) + 1

  # Also the link's accessible name: a narrow screen hides the word and shows
  # the number, and the number is decoration.
  defp step_name(:intro), do: "How it works"
  defp step_name(:agent), do: "Your agent"
  defp step_name(:github), do: "GitHub"
  defp step_name(:project), do: "First prompt"
end
