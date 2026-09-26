defmodule RavixWeb.Live.AgentPanel do
  @moduledoc """
  Which agent this person runs, and what pays for it: chosen, connected,
  replaced, reconnected, removed.

  The whole of a person's dealings with their credential happen here. What
  their set holds is read from Fountain (`Ravix.Accounts.Inference.held/1`)
  rather than taken from the row, so a slot emptied anywhere else shows as
  empty, and each thing held has its own Remove; nobody is sent to another
  console for any of it.

  Rendered in two places that must not drift: the walkthrough's agent step
  (`RavixWeb.OnboardingLive`), and the account dialog in the workspace
  (`RavixWeb.WorkspaceLive`), which is where somebody comes back to it
  weeks later. A `live_component` because the state is nobody else's --- the
  agent and kind being chosen, the credential form, the ChatGPT sign-in that
  is open --- and because the two pages would otherwise each carry a copy of
  the same eight assigns and nine event clauses.

  ## What the page keeps

  Two things a component cannot do for itself:

    * **The clock.** A ChatGPT sign-in is polled every few seconds, and a
      message can only be sent to the page's process. So the panel asks the
      page with `Process.send_after/3` and the page hands it back with
      `Phoenix.LiveView.send_update/2`; both pages have the one `handle_info`
      clause for it. The message goes through the page's session hook on the
      way, which is what stops the polling when the session has ended.

    * **What happens after.** Connecting changes the person, and the page is
      what holds `current_user`. The panel sends `{:agent_connected, user}`;
      the walkthrough moves on to GitHub, the workspace says so.

  ## The session

  A component's events do not pass through the page's session hooks, so
  every `live_component`'s `handle_event/3` is wrapped by
  `RavixWeb.Live.Hooks` and asks before each event itself, with the
  `session_hash` its page passes in. See that module for why it reads the
  row rather than holding a `RavixWeb.Live.Guard` of its own.

  ## The credential

  The value somebody pastes is sent to `Ravix.Accounts.Inference.connect/2`
  inside the task and nowhere else. It is never assigned: an assign is in the
  page's state and in its next diff, and the form is rebuilt empty whether the
  write worked or not. A ChatGPT sign-in has nothing to paste; what is
  assigned is the code and the attempt's id, which is what Fountain shows to
  anybody holding the account key anyway.
  """
  use RavixWeb, :live_component

  alias Ravix.Accounts.{Inference, User}
  alias RavixWeb.Live.Form

  # What the buttons send, as the atoms this module and the context use. Two
  # fixed tables rather than `String.to_existing_atom/1`: a browser must not be
  # able to name an atom the form never offered.
  @agents Map.new(User.agents(), &{to_string(&1), &1})
  @kinds %{"subscription" => :subscription, "api_key" => :api_key}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       credential_form: Form.new(:credential),
       busy: false,
       # The ChatGPT sign-in that is open, if one is; whether this Fountain
       # lets anybody start one (`nil` until asked); why the last one ended,
       # when it ended badly; and the subscription as Fountain reports it.
       link: nil,
       linking: nil,
       link_error: nil,
       subscription: nil,
       # What the set holds, as Fountain reports it: nil until it has answered.
       held: nil
     )}
  end

  # The page's clock, handed back: one poll of the open sign-in.
  @impl true
  def update(%{tick: :poll_link}, %{assigns: %{link: %Inference.Link{} = link}} = socket) do
    user = socket.assigns.current_user
    {:ok, traced_async(socket, :poll_link, fn -> Inference.poll_link(user, link) end)}
  end

  # The sign-in this tick was for has been cancelled or has finished.
  def update(%{tick: :poll_link}, socket), do: {:ok, socket}

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    user = socket.assigns.current_user

    # The choice opens on what the person has, and once: a later update from
    # the page (a new guard, a new user) must not undo what they are choosing.
    socket =
      if Map.has_key?(socket.assigns, :agent),
        do: socket,
        else:
          socket
          |> assign(agent: user.agent, kind: user.credential_kind || :subscription)
          |> read_link_status()
          |> read_subscription()
          |> read_held()

    {:ok, socket}
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

  # Remove one thing the set holds. Which one comes from the button and is
  # narrowed through the same two tables as a choice; the person is not asked
  # to confirm here because the browser already did (`data-confirm`).
  def handle_event(
        "disconnect",
        %{"agent" => a, "kind" => k},
        %{assigns: %{busy: false}} = socket
      )
      when is_map_key(@agents, a) and is_map_key(@kinds, k) do
    user = socket.assigns.current_user
    {agent, kind} = {Map.fetch!(@agents, a), Map.fetch!(@kinds, k)}

    {:noreply,
     socket
     |> assign(busy: true)
     |> traced_async(:disconnect, fn -> Inference.disconnect(user, agent, kind) end)}
  end

  # A word neither table holds is a browser saying something the form never
  # offered. Nothing to do and nothing to say.
  def handle_event(event, _params, socket)
      when event in ["choose-agent", "choose-kind", "disconnect"],
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
    # link the panel no longer holds, and is dropped by `handle_async/3`.
    {:noreply,
     socket
     |> assign(link: nil)
     |> traced_async(:cancel_link, fn -> Inference.cancel_link(user, link) end)}
  end

  def handle_event("cancel-link", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:connect, {:ok, response}, socket) do
    {:noreply,
     result(
       assign(socket, busy: false),
       response,
       fn s, %User{} = user -> connected(s, user) end,
       :credential_form
     )}
  end

  def handle_async(:link_status, {:ok, {:ok, %{enabled?: enabled?, pending: pending}}}, socket) do
    socket = assign(socket, linking: enabled?)

    # A sign-in found again is polled like one just started; one the panel
    # already holds is not replaced, since the panel is what started it.
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

  def handle_async(:poll_link, {:ok, {:ok, %User{} = user}}, socket),
    do: {:noreply, socket |> assign(link: nil) |> connected(user)}

  def handle_async(:poll_link, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, link: nil, link_error: RavixWeb.Error.from(reason).message)}

  # Nothing to draw for a cancel: the code is already gone from the panel.
  def handle_async(:cancel_link, {:ok, _result}, socket), do: {:noreply, socket}

  def handle_async(:subscription, {:ok, {:ok, subscription}}, socket),
    do: {:noreply, assign(socket, subscription: subscription)}

  # Nothing to say about a subscription Fountain would not describe.
  def handle_async(:subscription, _other, socket), do: {:noreply, socket}

  def handle_async(:held, {:ok, {:ok, held}}, socket) when is_list(held),
    do: {:noreply, assign(socket, held: held)}

  # A set Fountain would not list is not drawn as empty: empty is a claim.
  def handle_async(:held, _other, socket), do: {:noreply, socket}

  def handle_async(:disconnect, {:ok, response}, socket) do
    {:noreply,
     result(assign(socket, busy: false), response, fn s, %User{} = user ->
       disconnected(s, user)
     end)}
  end

  def handle_async(_name, {:exit, reason}, socket),
    do: {:noreply, socket |> assign(busy: false) |> exit(reason)}

  # The person changed. The panel shows what they now have, and the page is
  # told, since it is the page that holds them.
  defp connected(socket, %User{} = user) do
    send(self(), {:agent_connected, user})

    socket
    |> assign(current_user: user, agent: user.agent, kind: user.credential_kind)
    |> read_subscription()
    |> read_held()
  end

  # Something the person held has gone. The choice on the page stays where it
  # was, so what to connect instead is one paste away; the page is told, since
  # projects they own may now have nothing to run on.
  defp disconnected(socket, %User{} = user) do
    send(self(), {:agent_disconnected, user})

    socket
    |> assign(current_user: user, credential_form: Form.new(:credential))
    |> read_subscription()
    |> read_held()
  end

  # What the set holds, asked of Fountain off this process. The list is kept
  # while it is asked again, so a remove does not blank the section and
  # redraw it.
  defp read_held(socket) do
    user = socket.assigns.current_user
    traced_async(socket, :held, fn -> Inference.held(user) end)
  end

  # Only Codex on a subscription has a sign-in to look for. Asked off this
  # process, and only when the panel is not already showing one.
  defp read_link_status(%{assigns: %{agent: :codex, kind: :subscription, link: nil}} = socket) do
    user = socket.assigns.current_user
    traced_async(socket, :link_status, fn -> Inference.link_status(user) end)
  end

  defp read_link_status(socket), do: socket

  # Somebody connected this way has a subscription with a state worth seeing.
  defp read_subscription(socket) do
    case socket.assigns.current_user do
      %User{agent: :codex, credential_kind: :subscription} = user ->
        traced_async(socket, :subscription, fn -> Inference.subscription(user) end)

      _ ->
        assign(socket, subscription: nil)
    end
  end

  defp show_link(socket, %Inference.Link{} = link),
    do: socket |> assign(link: link, link_error: nil) |> schedule_poll()

  defp schedule_poll(
         %{assigns: %{link: %Inference.Link{poll_interval: seconds}, id: id}} = socket
       ) do
    Process.send_after(self(), {:agent_panel, id, :poll_link}, seconds * 1000)
    socket
  end

  defp schedule_poll(socket), do: socket

  # ── what the template asks ───────────────────────────────────────────

  defp agent_name(:claude), do: "Claude Code"
  defp agent_name(:codex), do: "Codex"

  defp kind_name(:subscription), do: "Subscription"
  defp kind_name(:api_key), do: "API key"

  # What the connected notice calls it, and what replacing it takes.
  defp paid_by(:codex, :subscription), do: "ChatGPT subscription"
  defp paid_by(_agent, :subscription), do: "subscription"
  defp paid_by(_agent, :api_key), do: "API key"

  defp replace_hint(agent, kind) do
    if Inference.pasted?(agent, kind),
      do: "Paste a new one to replace it",
      else: "Sign in again to reconnect it"
  end

  # Whether this held thing is the one the person's choice names.
  defp in_use?(%User{agent: agent, credential_kind: kind}, agent, kind), do: true
  defp in_use?(%User{}, _agent, _kind), do: false

  # The row says something pays for the agent; the set, read from Fountain,
  # says it does not. Said only once the set has answered.
  defp missing?(%User{} = user, held) when is_list(held),
    do: Inference.connected?(user) and {user.agent, user.credential_kind} not in held

  defp missing?(_user, _held), do: false

  defp remove_confirm(agent, kind, in_use?) do
    what = "#{agent_name(agent)}'s #{paid_by(agent, kind)}"

    tracks =
      if in_use?,
        do:
          " This ends your open tracks in every project you own, and those projects have nothing to run on until you connect something again.",
        else: " This ends your open tracks in every project you own."

    "Remove #{what} from Ravix?#{tracks} The #{paid_by(agent, kind)} itself is untouched."
  end

  # The subscription's state in a word, as a chip, and the rest in a line.
  defp subscription_state(%{status: "active", exhausted_until: until}) when is_binary(until),
    do: "Usage spent"

  defp subscription_state(%{status: "active"}), do: "Connected"
  defp subscription_state(%{status: "disconnected"}), do: "Disconnected"
  defp subscription_state(%{status: status}) when is_binary(status), do: "Reconnect required"
  defp subscription_state(_subscription), do: "Unknown"

  defp subscription_tone(%{status: "active", exhausted_until: until}) when is_binary(until),
    do: "warn"

  defp subscription_tone(%{status: "active"}), do: "ok"
  defp subscription_tone(_subscription), do: "bad"

  defp subscription_line(%{exhausted_until: until} = sub) when is_binary(until),
    do: "#{describe(sub)} Its plan is spent until #{until}; Codex runs are refused until then."

  defp subscription_line(%{status: "active"} = sub), do: describe(sub)

  defp subscription_line(sub),
    do: "#{describe(sub)} Codex runs on your projects are refused until you sign in again."

  defp describe(%{plan_type: plan, account_email: email}) do
    plan = if is_binary(plan), do: "ChatGPT #{String.capitalize(plan)}", else: "ChatGPT"
    if is_binary(email), do: "#{plan}, #{email}.", else: plan <> "."
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="agent-panel" id={@id}>
      <.loading_status :if={@busy}>Updating agent connection…</.loading_status>
      <div class="agent-choices" role="group" aria-label="Agent">
        <button
          :for={agent <- User.agents()}
          type="button"
          class={["agent-choice", @agent == agent && "on"]}
          aria-pressed={to_string(@agent == agent)}
          phx-click="choose-agent"
          phx-target={@myself}
          phx-value-agent={agent}
          id={"agent-#{agent}"}
        >
          <strong>{agent_name(agent)}</strong>
          <small :if={agent == :claude}>
            Anthropic's agent. Runs on a Claude Pro, Max or Team subscription, or an Anthropic API key.
          </small>
          <small :if={agent == :codex}>
            OpenAI's agent. Runs on a ChatGPT Plus, Pro, Business or Enterprise subscription, or an OpenAI API key.
          </small>
        </button>
      </div>

      <section
        :if={is_list(@held) and (@held != [] or missing?(@current_user, @held))}
        class="agent-held"
        id="agent-held"
        aria-label="What you have connected"
      >
        <p :if={missing?(@current_user, @held)} class="welcome-warning" id="held-missing">
          <.icon name="info" size={14} class="ico" />
          <span>
            Nothing is stored for {agent_name(@current_user.agent)} any more: its {paid_by(
              @current_user.agent,
              @current_user.credential_kind
            )} was removed outside this page. Projects you own have nothing to run on until you connect one again below.
          </span>
        </p>
        <ul :if={@held != []} class="agent-held-list">
          <li :for={{agent, kind} <- @held} id={"held-#{agent}-#{kind}"}>
            <span class="agent-held-name">
              <strong>{agent_name(agent)}</strong>
              <span class="dim">{paid_by(agent, kind)}</span>
              <span :if={in_use?(@current_user, agent, kind)} class="chip ok">In use</span>
            </span>
            <button
              type="button"
              class="ghost"
              phx-click="disconnect"
              phx-target={@myself}
              phx-value-agent={agent}
              phx-value-kind={kind}
              data-confirm={remove_confirm(agent, kind, in_use?(@current_user, agent, kind))}
              disabled={@busy}
              id={"remove-#{agent}-#{kind}"}
            >
              Remove
            </button>
          </li>
        </ul>
        <p :if={@held != []} class="hint">
          Removing one forgets it here; the subscription or key itself is untouched, and you can paste it or sign in again. Like replacing one, it ends your open tracks in every project you own.
        </p>
      </section>

      <div :if={@agent} class="agent-credential">
        <div class="workspace-actions" role="group" aria-label="How it is paid for">
          <button
            :for={kind <- Inference.kinds(@agent)}
            type="button"
            class={if @kind == kind, do: "primary", else: "ghost"}
            aria-pressed={to_string(@kind == kind)}
            phx-click="choose-kind"
            phx-target={@myself}
            phx-value-kind={kind}
            id={"kind-#{kind}"}
          >
            {kind_name(kind)}
          </button>
        </div>

        <p
          :if={
            Inference.connected?(@current_user) && @current_user.agent == @agent &&
              @current_user.credential_kind == @kind
          }
          class="welcome-connected"
          id="welcome-connected"
        >
          <.icon name="check" size={14} class="ico" />
          <span>
            {agent_name(@agent)} is connected with your {paid_by(@agent, @kind)}. {replace_hint(
              @agent,
              @kind
            )} — but replacing it ends your open tracks, in every project you own. A conversation will not carry on with a different credential than it started with, so you would open new ones.
          </span>
        </p>

        <p :if={@subscription} class="agent-subscription" id="chatgpt-subscription">
          <span class={["chip", subscription_tone(@subscription)]}>{subscription_state(@subscription)}</span>
          <span>{subscription_line(@subscription)}</span>
        </p>

        <ol :if={@agent == :claude && @kind == :subscription} class="agent-howto">
          <li>
            On a computer where Claude Code is signed in to your subscription, run <code>claude setup-token</code>.
          </li>
          <li>Approve it in the browser window that opens.</li>
          <li>Paste the token it prints. It starts with <code>sk-ant-oat01-</code>.</li>
        </ol>
        <ol :if={@agent == :claude && @kind == :api_key} class="agent-howto">
          <li>
            Create a key in the Anthropic Console, under <strong>API keys</strong>.
          </li>
          <li>
            Paste it here. It starts with <code>sk-ant-api</code>, and its usage is metered rather than part of a subscription.
          </li>
        </ol>
        <ol :if={@agent == :codex && @kind == :api_key} class="agent-howto">
          <li>
            Create a key on the OpenAI platform, under <strong>API keys</strong>.
          </li>
          <li>
            Paste it here. It starts with <code>sk-</code>, and its usage is metered rather than part of a subscription.
          </li>
        </ol>

        <div :if={@agent == :codex && @kind == :subscription} id="chatgpt-link">
          <ol class="agent-howto">
            <li>
              Press <strong>Connect ChatGPT</strong>. Ravix asks ChatGPT for a one-time code.
            </li>
            <li>
              Open the page it names in a browser signed in to the ChatGPT account whose plan should pay, and type the code.
            </li>
            <li>This page notices the approval by itself and moves on.</li>
          </ol>
          <p :if={@link_error} class="error" id="link-error" role="alert">{@link_error}</p>
          <p :if={@linking == false && is_nil(@link)} class="welcome-warning" id="linking-off">
            <.icon name="info" size={14} class="ico" />
            <span>
              Linking a ChatGPT subscription is not switched on for this Ravix deployment. Ask whoever runs it, or use an OpenAI API key for now.
            </span>
          </p>
          <div :if={@link} class="agent-code" id="chatgpt-code" aria-live="polite">
            <p class="agent-code-value">
              <span class="hint">Your code</span>
              <strong id="chatgpt-user-code">{@link.user_code}</strong>
            </p>
            <p>
              Enter it at
              <a
                :if={@link.trusted?}
                href={@link.verification_url}
                target="_blank"
                rel="noopener noreferrer"
                id="chatgpt-verification"
              >{@link.verification_url}</a><code :if={!@link.trusted?} id="chatgpt-verification">{@link.verification_url}</code>. Whoever types this code lets this Ravix spend their ChatGPT plan, so only type it if you started this sign-in yourself, on this page, just now. Nobody at Ravix will ever send you a code.
            </p>
            <p class="hint">
              Waiting for ChatGPT… the code is good for fifteen minutes, and you can close this page and come back.
            </p>
            <div class="workspace-actions">
              <button
                type="button"
                class="ghost"
                phx-click="cancel-link"
                phx-target={@myself}
                id="chatgpt-cancel"
              >
                Cancel
              </button>
            </div>
          </div>
          <div :if={is_nil(@link) && @linking != false} class="workspace-actions">
            <button
              type="button"
              class="primary"
              phx-click="begin-link"
              phx-target={@myself}
              disabled={@busy}
              id="chatgpt-connect"
            >
              {if @busy, do: "Asking ChatGPT…", else: "Connect ChatGPT"}
            </button>
          </div>
          <p class="hint">
            The sign-in is kept encrypted with the machines that run your agent and renewed for you. No token is ever shown — not to you, not to teammates, and not on this page. Removing it above forgets it here; it cannot sign you out of ChatGPT, so do that in your ChatGPT account if you want to.
          </p>
        </div>

        <.form
          :let={f}
          :if={Inference.pasted?(@agent, @kind)}
          for={@credential_form}
          id="credential-form"
          phx-submit="connect"
          phx-target={@myself}
          autocomplete="off"
        >
          <.input
            field={f[:value]}
            id="credential-value"
            type="password"
            label={if @kind == :subscription, do: "Subscription token", else: "API key"}
            autocomplete="off"
            required
          />
          <p class="hint">
            Stored encrypted with the machines that run your agent and never shown again — not to you, not to teammates, and not on this page. You can remove it here whenever you like.
          </p>
          <button class="primary" disabled={@busy} phx-disable-with="Connecting…">
            Connect {agent_name(@agent)}
          </button>
        </.form>
      </div>
    </div>
    """
  end
end
