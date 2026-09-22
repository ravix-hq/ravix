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

  ## The credential

  The value somebody pastes is sent to `Ravix.Accounts.Inference.connect/2`
  inside the task and nowhere else. It is never assigned: an assign is in the
  page's state and in its next diff, and the form is rebuilt empty whether the
  write worked or not. That is the rule `RavixWeb.Live.SettingsDialog` keeps
  for a project's secrets, for the same reason.

  ## The ChatGPT sign-in

  Codex on a ChatGPT subscription has nothing to paste. The page asks
  `Ravix.Accounts.Inference.begin_link/1` for a one-time code, shows it with
  the page to type it on, and then asks `poll_link/2` every few seconds ---
  `Process.send_after/3` to itself, each tick a `start_async/3` --- until
  ChatGPT has approved it or the sign-in has ended. The `:poll_link` message
  goes through the same session hook as every other, so a session that ended
  meanwhile stops the polling with the page. What is assigned is the code
  and the attempt's id, which is what Fountain shows to anybody holding the
  account key anyway; no token ever passes through here. Arriving on the
  step reads `link_status/1` first, so a reload during a sign-in shows the
  same code rather than starting another, and a Fountain where nobody may
  link says so instead of offering a button.
  """
  use RavixWeb, :live_view

  alias Ravix.{Accounts, Projects}
  alias Ravix.Accounts.{Inference, User}
  alias RavixWeb.Live.Form
  alias RavixWeb.Live.Guard

  @steps [:intro, :agent, :github, :project]
  @paths %{
    intro: "/welcome",
    agent: "/welcome/agent",
    github: "/welcome/github",
    project: "/welcome/project"
  }

  # What the buttons send, as the atoms this module and the context use. Two
  # fixed tables rather than `String.to_existing_atom/1`: a browser must not be
  # able to name an atom the form never offered.
  @agents Map.new(User.agents(), &{to_string(&1), &1})
  @kinds %{"subscription" => :subscription, "api_key" => :api_key}

  @doc "The steps, in order, with the path each lives at."
  @spec steps() :: [{atom(), String.t()}]
  def steps, do: Enum.map(@steps, &{&1, @paths[&1]})

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    {:ok,
     assign(socket,
       session_token: session["session_token"],
       github_available: Accounts.capabilities().github,
       agent: user && user.agent,
       kind: (user && user.credential_kind) || :subscription,
       credential_form: Form.new(:credential),
       project_form: Form.new(:new_project),
       # `nil` until GitHub has answered, which is not the same as "none": the
       # GitHub step says "checking" for the first and offers the install
       # button for the second.
       installations: nil,
       installation: nil,
       repos: [],
       busy: false,
       # The ChatGPT sign-in that is open, if one is; whether this Fountain
       # lets anybody start one (`nil` until asked); and why the last one
       # ended, when it ended badly.
       link: nil,
       linking: nil,
       link_error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = validate_session(socket)

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

  # The two steps that read GitHub do it on arrival and off this process, and
  # the agent step reads whether a ChatGPT sign-in is open the same way.
  defp enter(socket, step) when step in [:github, :project], do: load_repos(socket, nil)
  defp enter(socket, :agent), do: read_link_status(socket)
  defp enter(socket, _step), do: socket

  # A URL patch is not a message, so no hook has run for it. See the same
  # function in `RavixWeb.WorkspaceLive`.
  defp validate_session(%{assigns: %{current_user: nil}} = socket), do: socket

  defp validate_session(socket) do
    hash = Ravix.Crypto.sha256(socket.assigns.session_token)

    case Guard.verify(socket.assigns[:session_guard], hash) do
      {:ok, guard} -> assign(socket, session_guard: guard)
      :error -> assign(socket, current_user: nil)
    end
  end

  @impl true
  def handle_event("choose-agent", %{"agent" => word}, socket) when is_map_key(@agents, word) do
    agent = Map.fetch!(@agents, word)
    kinds = Inference.kinds(agent)
    kind = if socket.assigns.kind in kinds, do: socket.assigns.kind, else: hd(kinds)

    {:noreply,
     socket
     |> assign(agent: agent, kind: kind, credential_form: Form.new(:credential))
     |> read_link_status()}
  end

  def handle_event("choose-kind", %{"kind" => word}, socket) when is_map_key(@kinds, word) do
    kind = Map.fetch!(@kinds, word)

    if socket.assigns.agent && kind in Inference.kinds(socket.assigns.agent),
      do:
        {:noreply,
         socket
         |> assign(kind: kind, credential_form: Form.new(:credential))
         |> read_link_status()},
      else: {:noreply, socket}
  end

  def handle_event("begin-link", _params, %{assigns: %{link: nil, busy: false}} = socket) do
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(busy: true, link_error: nil)
     |> traced_async(:begin_link, fn -> Inference.begin_link(user) end)}
  end

  def handle_event("begin-link", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-link", _params, %{assigns: %{link: %Inference.Link{} = link}} = socket) do
    user = socket.assigns.current_user

    # Forgotten here first: a poll already in flight for it answers to a
    # link the page no longer holds, and is dropped by `handle_async/3`.
    {:noreply,
     socket
     |> assign(link: nil)
     |> traced_async(:cancel_link, fn -> Inference.cancel_link(user, link) end)}
  end

  def handle_event("cancel-link", _params, socket), do: {:noreply, socket}

  # A word neither table holds is a browser saying something the form never
  # offered. Nothing to do and nothing to say.
  def handle_event(event, _params, socket) when event in ["choose-agent", "choose-kind"],
    do: {:noreply, socket}

  def handle_event("connect", %{"credential" => %{"value" => value}}, socket)
      when is_binary(value) do
    %{current_user: user, agent: agent, kind: kind} = socket.assigns
    attrs = %{agent: agent, kind: kind, value: value}

    # The field is given back empty, not absent: `used_input?/1` is what lets a
    # refusal show beside it, and it reads whether the field was submitted.
    {:noreply,
     socket
     |> assign(busy: true, credential_form: Form.new(:credential, %{"value" => ""}))
     |> traced_async(:connect, fn -> Inference.connect(user, attrs) end)}
  end

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
    attrs = Map.take(params, ["name"])

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
  def handle_info(:poll_link, %{assigns: %{link: %Inference.Link{} = link}} = socket) do
    user = socket.assigns.current_user
    {:noreply, traced_async(socket, :poll_link, fn -> Inference.poll_link(user, link) end)}
  end

  # The sign-in this tick was for has been cancelled or has finished.
  def handle_info(:poll_link, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:connect, {:ok, response}, socket) do
    {:noreply,
     result(
       assign(socket, busy: false),
       response,
       fn s, %User{} = user ->
         s
         |> assign(current_user: user, agent: user.agent, kind: user.credential_kind)
         |> push_patch(to: @paths[:github])
       end,
       :credential_form
     )}
  end

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

  def handle_async(:link_status, {:ok, {:ok, %{enabled?: enabled?, pending: pending}}}, socket) do
    socket = assign(socket, linking: enabled?)

    # A sign-in found again is polled like one just started; one the page
    # already holds is not replaced, since the page is what started it.
    case {socket.assigns.link, pending} do
      {nil, %Inference.Link{} = link} -> {:noreply, show_link(socket, link)}
      _ -> {:noreply, socket}
    end
  end

  # Fountain could not be asked. The button stays: pressing it asks again,
  # and says what went wrong in words if it still cannot.
  def handle_async(:link_status, _other, socket), do: {:noreply, socket}

  def handle_async(:begin_link, {:ok, {:ok, %Inference.Link{} = link}}, socket),
    do: {:noreply, socket |> assign(busy: false) |> show_link(link)}

  def handle_async(:begin_link, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, busy: false, link_error: RavixWeb.Error.from(reason).message)}

  def handle_async(:poll_link, {:ok, {:ok, :pending}}, socket),
    do: {:noreply, schedule_poll(socket)}

  def handle_async(:poll_link, {:ok, {:ok, %User{} = user}}, socket) do
    {:noreply,
     socket
     |> assign(current_user: user, agent: user.agent, kind: user.credential_kind, link: nil)
     |> push_patch(to: @paths[:github])}
  end

  def handle_async(:poll_link, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, link: nil, link_error: RavixWeb.Error.from(reason).message)}

  # Nothing to draw for a cancel: the code is already gone from the page.
  def handle_async(:cancel_link, {:ok, _result}, socket), do: {:noreply, socket}

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

  def handle_async(_name, {:exit, _reason}, socket),
    do:
      {:noreply,
       socket
       |> assign(busy: false)
       |> put_flash(:error, "The operation could not finish. Refresh and try again.")}

  # Only Codex on a subscription has a sign-in to look for. Asked off this
  # process, and only when the page is not already showing one.
  defp read_link_status(%{assigns: %{agent: :codex, kind: :subscription, link: nil}} = socket) do
    user = socket.assigns.current_user
    traced_async(socket, :link_status, fn -> Inference.link_status(user) end)
  end

  defp read_link_status(socket), do: socket

  defp show_link(socket, %Inference.Link{} = link),
    do: socket |> assign(link: link, link_error: nil) |> schedule_poll()

  defp schedule_poll(%{assigns: %{link: %Inference.Link{poll_interval: seconds}}} = socket) do
    Process.send_after(self(), :poll_link, seconds * 1000)
    socket
  end

  defp schedule_poll(socket), do: socket

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

  defp agent_name(:claude), do: "Claude Code"
  defp agent_name(:codex), do: "Codex"

  defp kind_name(:subscription), do: "Subscription"
  defp kind_name(:api_key), do: "API key"

  # What the connected notice calls it, and what replacing it takes.
  defp paid_by(:codex, :subscription), do: "ChatGPT subscription"
  defp paid_by(_agent, kind), do: String.downcase(kind_name(kind))

  defp replace_hint(agent, kind) do
    if Inference.pasted?(agent, kind),
      do: "Paste a new one to replace it",
      else: "Sign in again to reconnect it"
  end
end
