defmodule RavixWeb.OnboardingLive do
  @moduledoc """
  The first visit: what Ravix is, then the three things a first project needs.

  Four steps, each its own URL so that the back button, a reload and the round
  trip to GitHub all land somewhere sensible:

      /welcome            how the app works
      /welcome/agent      Claude Code or Codex, and the subscription or key for it
      /welcome/github     install the GitHub App on the repositories to work in
      /welcome/project    pick one of them, and the machine is built

  ## Nothing here is a gate

  `RavixWeb.WorkspaceLive` sends somebody here when they have no project and
  have never finished or dismissed this, and that is the only push. Every step
  can be skipped, because each has a legitimate reason to be: somebody invited
  to a teammate's project runs on *that* person's subscription and needs none of
  their own, and a scratch project needs no repository. What a step does is
  done by the same context call the rest of the app uses ---
  `Ravix.Accounts.Inference.connect/2`, `Ravix.Projects.create/2` --- so
  skipping one leaves nothing half-made that the workspace cannot finish later.

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
  later cannot drift. What the page keeps is what a component cannot do:
  hand the panel its polling tick, and move on to GitHub once the panel says
  the person is connected.
  """
  use RavixWeb, :live_view

  alias Ravix.{Accounts, Projects}
  alias Ravix.Accounts.{Inference, User}
  alias RavixWeb.Live.{AgentPanel, Form, Guard}

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
       project_form: Form.new(:new_project),
       # `nil` until GitHub has answered, which is not the same as "none": the
       # GitHub step says "checking" for the first and offers the install
       # button for the second.
       installations: nil,
       installation: nil,
       repos: [],
       busy: false
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
  defp step_title(:project), do: "Create your first project"

  # The two steps that read GitHub do it on arrival and off this process.
  defp enter(socket, step) when step in [:github, :project], do: load_repos(socket, nil)
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

  def handle_event("edit", %{"new_project" => params}, socket),
    do: {:noreply, assign(socket, project_form: Form.new(:new_project, params))}

  def handle_event("create-project", %{"new_project" => params}, socket) do
    repo = Enum.find(socket.assigns.repos, &(&1.full_name == params["repo"]))
    attrs = Map.take(params, ["name", "runtime"])

    attrs =
      if repo,
        do:
          Map.merge(attrs, %{"repo" => repo.full_name, "installation_id" => repo.installation_id}),
        else: attrs

    user = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(busy: true, project_form: Form.new(:new_project, params))
     |> traced_async(:create_project, fn -> Projects.create(user, attrs) end)}
  end

  # Leaving without finishing is finishing: the workspace must not send
  # somebody back here every time they open it.
  def handle_event("skip", _params, socket) do
    {:noreply, socket |> finish() |> push_navigate(to: "/home")}
  end

  @impl true
  # The agent panel's clock; see `RavixWeb.Live.AgentPanel`.
  def handle_info({:agent_panel, id, tick}, socket) do
    send_update(AgentPanel, id: id, tick: tick)
    {:noreply, socket}
  end

  # The panel connected something. That was the step; on to GitHub.
  def handle_info({:agent_connected, %User{} = user}, socket),
    do: {:noreply, socket |> assign(current_user: user) |> push_patch(to: @paths[:github])}

  # The panel removed something. The step is not done by that; it stays.
  def handle_info({:agent_disconnected, %User{} = user}, socket),
    do: {:noreply, assign(socket, current_user: user)}

  # The panel cannot put a flash in the page's own socket; see
  # `RavixWeb.Live.Result.flash/3`. The clear is its timer for a notice.
  def handle_info({:flash, kind, message}, socket),
    do: {:noreply, flash(socket, kind, message)}

  def handle_info({:clear_flash, kind, message}, socket),
    do: {:noreply, clear_notice(socket, kind, message)}

  @impl true
  def handle_async(:create_project, {:ok, response}, socket) do
    {:noreply,
     result(
       assign(socket, busy: false),
       response,
       # Straight into the new-track dialog: a project with nothing in it is
       # not what anybody came for, and the first conversation is one click.
       fn s, project -> s |> finish() |> push_navigate(to: "/p/#{project.id}?new=track") end,
       :project_form
     )}
  end

  def handle_async(:repos, {:ok, {:ok, data}}, socket) do
    {:noreply,
     assign(socket,
       repos: data.repos,
       installations: data.installations,
       installation: data.selected
     )}
  end

  # GitHub could not be read. "None" is the honest thing to draw: the install
  # button is also how somebody whose token has gone gets a working one.
  def handle_async(:repos, _other, socket),
    do: {:noreply, assign(socket, repos: [], installations: [], installation: nil)}

  def handle_async(_name, {:exit, reason}, socket),
    do: {:noreply, socket |> assign(busy: false) |> exit(reason)}

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
      |> assign(repos: [], installation: nil)
      |> traced_async(:repos, fn -> Projects.repos(user, id) end)
    else
      assign(socket, repos: [], installations: [], installation: nil)
    end
  end

  # ── what the template asks ───────────────────────────────────────────

  defp path(step), do: Map.fetch!(@paths, step)

  defp position(step), do: Enum.find_index(@steps, &(&1 == step)) + 1

  # Also the link's accessible name: a narrow screen hides the word and shows
  # the number, and the number is decoration.
  defp step_name(:intro), do: "How it works"
  defp step_name(:agent), do: "Your agent"
  defp step_name(:github), do: "GitHub"
  defp step_name(:project), do: "First project"
end
