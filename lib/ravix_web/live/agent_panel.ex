defmodule RavixWeb.Live.AgentPanel do
  @moduledoc """
  Connected agents and the default for new projects: chosen, connected,
  replaced, reconnected, removed.

  The whole of a person's dealings with their credential happen here. What
  their set holds is read from Fountain (`Ravix.Accounts.Inference.held/1`)
  rather than taken from the row, so a slot emptied anywhere else shows as
  empty, and each thing held has its own Remove; nobody is sent to another
  console for any of it.

  Rendered in the walkthrough's agent step
  (`RavixWeb.OnboardingLive`); on Settings › Agents
  (`RavixWeb.Live.PersonalSettings`), which is where somebody comes back to
  it weeks later; in the account dialog a reconnect opens in the workspace
  (`RavixWeb.WorkspaceLive`); and scoped to one agent inside the shared
  new-project form.
  A `live_component` because the state is nobody else's --- the
  agent and kind being chosen, the credential form, the ChatGPT sign-in that
  is open --- and because the two pages would otherwise each carry a copy of
  the same eight assigns and nine event clauses.

  ## Compact

  The walkthrough and Settings › Agents pass `compact={true}` and get one
  decision (RAV-41, RAV-77): a card per agent saying Connect, or ✓ Connected
  with Make default, and the steps for the one being connected. What else
  there is to do with an agent -- pay for it the other way, replace or
  reconnect what is held, remove it -- is in the card's ⋯ menu, and the
  warning that it ends open tracks is said in the steps or confirmation
  that follow, not on the card. The default model for new threads is
  behind a disclosure. A first connection becomes the default in
  `Ravix.Accounts.Inference.connect/2`, so there is nothing to choose until
  there are two.

  ## What the page keeps

  Two things a component cannot do for itself:

    * **The clock.** A ChatGPT sign-in is polled every few seconds, and a
      message can only be sent to the page's process. So the panel asks the
      page with `Process.send_after/3` and the page hands it back with
      `Phoenix.LiveView.send_update/2`; both pages have the one `handle_info`
      clause for it. The message goes through the page's session hook on the
      way, which is what stops the polling when the session has ended.

    * **What happens after.** Connecting changes the person, and the page is
      what holds `current_user`. The panel sends `{:agent_connected, user, agent}`;
      the standalone walkthrough offers another connection; an inline connection
      keeps the project draft and selected agent. Pages route clock messages only
      while that panel is visible. Each dialog opening and panel mount has its
      own identity, so an old tick cannot poll a later sign-in.

  ## The session

  A component's events do not pass through the page's session hooks, so
  every `live_component`'s `handle_event/3` is wrapped by
  `RavixWeb.Live.Hooks` and asks before each event itself, with the
  `session_hash` its page passes in. See that module for why it reads the
  row rather than holding a `RavixWeb.Live.Guard` of its own.

  ## The credential

  The value somebody pastes is sent to `Ravix.Accounts.Inference.connect/2`
  inside the task and nowhere else. It is never assigned: an assign is in the
  page's state and in its next diff, and the form is rendered with no value
  whether the write worked or not. What the field shows while Fountain is
  asked, and still after a refusal, is the browser's own copy of the paste:
  the input is `phx-update="ignore"` and the `CredentialField` hook
  (`assets/js/hooks/credential_field.js`) clears it when the server says the
  attempt is over (RAV-135). A ChatGPT sign-in has nothing to paste; what is
  assigned is the code and the attempt's id, which is what Fountain shows to
  anybody holding the account key anyway.

  ## The connect step

  The steps, the field and its button are one card headed "Connect …"
  (RAV-133), so that inside the new-project dialog they read as a sub-step
  and not as the dialog's own submit: the button is the card's, right-aligned
  and plain, and Add repository stays the one primary action. An empty submit
  is refused here, on the field, rather than by the browser's `required`
  (RAV-134), whose bubble covered the hint and stayed up until the next
  click. While Fountain is asked, the button itself says so in the width it
  already had, and nothing is inserted above the form (RAV-135); `pending`
  names the action whose button is showing its own progress, and the
  "Updating agent connection…" line is kept for the ones that have no button
  to show it in (Make default, Remove).

  ## An account already linked

  A refused ChatGPT sign-in is usually the person's own subscription in the way
  (`Ravix.Accounts.Inference.Conflict`). The classified refusal is held here so
  the repair can be a button: the *panel* says which repair it is and which
  grant, never the browser, and the context classifies it again from Fountain
  before it writes. A refusal about another Ravix login's subscription gets a
  sentence and no button, because there is nothing on this page they may press.
  """
  use RavixWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Ravix.Accounts.{Inference, ThreadPreference, User}
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
       # The action whose own button is showing its progress (`:connect`,
       # `:begin_link`), while `busy`; nil when the status line says it.
       pending: nil,
       # The ChatGPT sign-in that is open, if one is; whether this Fountain
       # lets anybody start one (`nil` until asked); why the last one ended,
       # when it ended badly; the classified "already linked" refusal, when
       # that is why; and the subscription as Fountain reports it.
       link: nil,
       linking: nil,
       link_error: nil,
       link_conflict: nil,
       subscription: nil,
       # What the set holds, as Fountain reports it: nil until it has answered.
       held: nil,
       thread_defaults: nil,
       thread_default_error: nil,
       thread_default_saved: false,
       scoped_agent: nil,
       onboarding: false,
       # The walkthrough's one decision (`compact`): a card per agent with
       # Connect or Connected, the steps for the one being connected
       # (`connecting`), and the rest behind Manage (`manage_open`).
       compact: false,
       connecting: false,
       manage_open: false,
       poll_token: make_ref(),
       disconnect_confirmation: nil
     )}
  end

  # The page's clock, handed back: one poll of the open sign-in.
  @impl true
  def update(%{tick: :poll_link}, %{assigns: %{scoped_agent: nil, poll_token: token}} = socket),
    do: update(%{tick: {:poll_link, token}}, socket)

  def update(
        %{tick: {:poll_link, token}},
        %{assigns: %{link: %Inference.Link{} = link, poll_token: token}} = socket
      ) do
    user = socket.assigns.current_user
    {:ok, traced_async(socket, :poll_link, fn -> Inference.poll_link(user, link) end)}
  end

  # The sign-in this tick was for has been cancelled or has finished.
  def update(%{tick: _tick}, socket), do: {:ok, socket}

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
          |> assign(
            agent: socket.assigns.scoped_agent || Map.get(assigns, :initial_agent) || user.agent,
            kind:
              if(socket.assigns.scoped_agent,
                do: :subscription,
                else: user.credential_kind || :subscription
              )
          )
          |> read_link_status()
          |> read_subscription()
          |> read_held()

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "save-thread-default",
        %{"preference" => %{"choice" => choice}},
        %{assigns: %{busy: false, scoped_agent: nil, thread_defaults: %{}}} = socket
      )
      when is_binary(choice) do
    case String.split(choice, "|", parts: 2) do
      [runtime, model] ->
        user = socket.assigns.current_user

        {:noreply,
         socket
         |> assign(busy: true, thread_default_saved: false, thread_default_error: nil)
         |> traced_async(:thread_default, fn ->
           ThreadPreference.save(user, runtime, model)
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("change-thread-default", _params, socket),
    do: {:noreply, assign(socket, thread_default_saved: false, thread_default_error: nil)}

  def handle_event("save-thread-default", _params, socket), do: {:noreply, socket}

  def handle_event("choose-agent", _, %{assigns: %{scoped_agent: agent}} = socket)
      when not is_nil(agent), do: {:noreply, socket}

  def handle_event("choose-agent", %{"agent" => word}, %{assigns: %{busy: false}} = socket)
      when is_map_key(@agents, word) do
    agent = Map.fetch!(@agents, word)
    kinds = Inference.kinds(agent)
    kind = if socket.assigns.kind in kinds, do: socket.assigns.kind, else: hd(kinds)

    {:noreply,
     socket
     |> assign(agent: agent, kind: kind, connecting: true, credential_form: Form.new(:credential))
     |> read_link_status()}
  end

  def handle_event("choose-kind", %{"kind" => word}, %{assigns: %{busy: false}} = socket)
      when is_map_key(@kinds, word) do
    kind = Map.fetch!(@kinds, word)

    if socket.assigns.agent && kind in Inference.kinds(socket.assigns.agent),
      do:
        {:noreply,
         socket
         |> assign(kind: kind, connecting: true, credential_form: Form.new(:credential))
         |> read_link_status()},
      else: {:noreply, socket}
  end

  # A card menu's "Connect with an API key", "Replace your subscription"
  # and the like: both choices at once. Bounded by the same two tables.
  def handle_event(
        "connect-with",
        %{"agent" => a, "kind" => k},
        %{assigns: %{busy: false, scoped_agent: nil}} = socket
      )
      when is_map_key(@agents, a) and is_map_key(@kinds, k) do
    {agent, kind} = {Map.fetch!(@agents, a), Map.fetch!(@kinds, k)}

    if kind in Inference.kinds(agent),
      do:
        {:noreply,
         socket
         |> assign(
           agent: agent,
           kind: kind,
           connecting: true,
           credential_form: Form.new(:credential)
         )
         |> read_link_status()},
      else: {:noreply, socket}
  end

  def handle_event("toggle-manage", _params, socket),
    do: {:noreply, assign(socket, manage_open: !socket.assigns.manage_open)}

  def handle_event("make-default", %{"agent" => word}, %{assigns: %{busy: false}} = socket)
      when is_map_key(@agents, word) do
    user = socket.assigns.current_user
    agent = Map.fetch!(@agents, word)

    {:noreply,
     socket
     |> assign(busy: true)
     |> traced_async(:make_default, fn -> Inference.make_default(user, agent) end)}
  end

  def handle_event(
        "disconnect",
        %{"agent" => a, "kind" => k},
        %{assigns: %{busy: false, disconnect_confirmation: nil}} = socket
      )
      when is_map_key(@agents, a) and is_map_key(@kinds, k) do
    {agent, kind} = {Map.fetch!(@agents, a), Map.fetch!(@kinds, k)}
    projects = Ravix.Projects.projects_using_agent(socket.assigns.current_user, agent)

    {:noreply,
     assign(socket, disconnect_confirmation: %{agent: agent, kind: kind, projects: projects})}
  end

  def handle_event("cancel-disconnect", _, socket),
    do: {:noreply, assign(socket, disconnect_confirmation: nil)}

  def handle_event(
        "confirm-disconnect",
        _,
        %{assigns: %{busy: false, disconnect_confirmation: %{} = confirmation}} = socket
      ) do
    user = socket.assigns.current_user
    %{agent: agent, kind: kind} = confirmation

    {:noreply,
     socket
     |> assign(busy: true, disconnect_confirmation: nil, disconnecting_agent: agent)
     |> traced_async(:disconnect, fn -> Inference.disconnect(user, agent, kind) end)}
  end

  def handle_event("confirm-disconnect", _, socket), do: {:noreply, socket}

  # A word neither table holds is a browser saying something the form never
  # offered. Nothing to do and nothing to say.
  def handle_event(event, _params, socket)
      when event in ["choose-agent", "choose-kind", "connect-with", "disconnect", "make-default"],
      do: {:noreply, socket}

  def handle_event("connect", _params, %{assigns: %{busy: true}} = socket),
    do: {:noreply, socket}

  # Nothing pasted: said beside the field, and nothing sent (RAV-134). The
  # context refuses an empty value too (`Inference.connect/2`); this is the
  # sentence for the field it is about, not a second copy of the rule.
  def handle_event("connect", %{"credential" => %{"value" => value}}, socket)
      when is_binary(value) do
    %{current_user: user, agent: agent, kind: kind} = socket.assigns

    if String.trim(value) == "" do
      {:ok, form} =
        Form.refuse(
          Form.new(:credential),
          {:unprocessable, "no_credential", empty_message(agent, kind)}
        )

      {:noreply, assign(socket, credential_form: form)}
    else
      attrs = %{agent: agent, kind: kind, value: value}
      track_inline(socket, :inline_connect_started, agent, kind)

      # The form is left as it is until the answer comes: a refusal still
      # beside the field is replaced then, not cleared now, so a retry moves
      # nothing under the button (RAV-135). The field's value is the
      # browser's own copy (see "The credential"); the server renders none.
      {:noreply,
       socket
       |> assign(busy: true, pending: :connect)
       |> traced_async(:connect, fn -> Inference.connect(user, attrs) end)}
    end
  end

  def handle_event("begin-link", _params, %{assigns: %{link: nil, busy: false}} = socket) do
    user = socket.assigns.current_user
    track_inline(socket, :inline_connect_started, :codex, :subscription)

    {:noreply,
     socket
     |> assign(busy: true, pending: :begin_link, link_error: nil, link_conflict: nil)
     |> traced_async(:begin_link, fn -> Inference.begin_link(user) end)}
  end

  def handle_event("begin-link", _params, socket), do: {:noreply, socket}

  # The repair for an "already linked" refusal: reconnect the person's own
  # grant, or remove a stray one and start over. Which of the two, and which
  # grant, is the conflict the panel is holding and never anything the browser
  # sent: a grant id from a form is a grant id anybody could name. The context
  # classifies it again before it touches Fountain, so a stale one here can
  # only be refused, not acted on.
  def handle_event(
        "resolve-conflict",
        _params,
        %{assigns: %{busy: false, link_conflict: %Inference.Conflict{} = conflict}} = socket
      )
      when conflict.resolution in [:reconnect, :remove] do
    user = socket.assigns.current_user

    # The conflict stays until the answer comes back, so the button is still
    # there to be disabled rather than vanishing under the press. `busy` is
    # what stops a second press starting a second attempt.
    {:noreply,
     socket
     |> assign(busy: true, link_error: nil)
     |> traced_async(:begin_link, fn -> Inference.resolve_conflict(user, conflict) end)}
  end

  def handle_event("resolve-conflict", _params, socket), do: {:noreply, socket}

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
  # The answer: a fresh form, carrying the refusal if that is what it is.
  def handle_async(:connect, {:ok, response}, socket) do
    {:noreply,
     result(
       assign(socket, busy: false, pending: nil, credential_form: Form.new(:credential)),
       response,
       fn s, %User{} = user -> connected(s, user, s.assigns.agent, s.assigns.kind) end,
       :credential_form
     )}
  end

  def handle_async(:make_default, {:ok, response}, socket) do
    {:noreply,
     result(assign(socket, busy: false), response, fn s, user ->
       send(self(), {:agent_default_changed, user})
       s |> assign(current_user: user) |> read_held()
     end)}
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
    do:
      {:noreply,
       socket |> assign(busy: false, pending: nil, link_conflict: nil) |> show_link(link)}

  # Whatever the refusal was, the conflict the page was holding is spent: the
  # context has just read the account again and this is what it says now.
  def handle_async(:begin_link, {:ok, {:error, reason}}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         pending: nil,
         link_conflict: nil,
         link_error: RavixWeb.Error.from(reason).message
       )}

  def handle_async(:poll_link, {:ok, {:ok, :pending}}, socket),
    do: {:noreply, schedule_poll(socket)}

  def handle_async(:poll_link, {:ok, {:ok, %User{} = user}}, socket),
    do: {:noreply, socket |> assign(link: nil) |> connected(user, :codex, :subscription)}

  # The ChatGPT account is held by a grant on this Fountain. The sentence says
  # whose, as far as this person may be told; the conflict is kept so the
  # button that repairs it has something to repair.
  def handle_async(
        :poll_link,
        {:ok, {:error, {:link_conflict, %Inference.Conflict{} = conflict}}},
        socket
      ),
      do:
        {:noreply,
         assign(socket, link: nil, link_conflict: conflict, link_error: conflict.message)}

  def handle_async(:poll_link, {:ok, {:error, reason}}, socket),
    do:
      {:noreply,
       assign(socket,
         link: nil,
         link_conflict: nil,
         link_error: RavixWeb.Error.from(reason).message
       )}

  # Nothing to draw for a cancel: the code is already gone from the panel.
  def handle_async(:cancel_link, {:ok, _result}, socket), do: {:noreply, socket}

  def handle_async(:subscription, {:ok, {:ok, subscription}}, socket),
    do: {:noreply, assign(socket, subscription: subscription)}

  # Nothing to say about a subscription Fountain would not describe.
  def handle_async(:subscription, _other, socket), do: {:noreply, socket}

  def handle_async(:held, {:ok, {:ok, held}}, socket) when is_list(held) do
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(held: held)
     |> traced_async(:thread_defaults, fn ->
       ThreadPreference.options(user, held)
     end)}
  end

  def handle_async(:thread_defaults, {:ok, {:ok, defaults}}, socket),
    do: {:noreply, assign(socket, thread_defaults: defaults)}

  def handle_async(:thread_defaults, _result, socket), do: {:noreply, socket}

  def handle_async(:thread_default, {:ok, {:ok, user}}, socket) do
    send(self(), {:agent_default_changed, user})

    defaults = %{
      socket.assigns.thread_defaults
      | preference: %{
          runtime: to_string(user.preferred_runtime),
          model: user.preferred_model
        }
    }

    {:noreply,
     assign(socket,
       current_user: user,
       busy: false,
       thread_defaults: defaults,
       thread_default_error: nil,
       thread_default_saved: true
     )}
  end

  def handle_async(:thread_default, {:ok, {:error, reason}}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         thread_default_saved: false,
         thread_default_error: RavixWeb.Error.from(reason).message
       )}

  # A set Fountain would not list is not drawn as empty: empty is a claim.
  def handle_async(:held, _other, socket), do: {:noreply, socket}

  def handle_async(:disconnect, {:ok, response}, socket) do
    {:noreply,
     result(assign(socket, busy: false), response, fn s, %User{} = user ->
       disconnected(s, user)
     end)}
  end

  def handle_async(_name, {:exit, reason}, socket),
    do: {:noreply, socket |> assign(busy: false, pending: nil) |> exit(reason)}

  # The person changed. The panel shows what they now have, and the page is
  # told, since it is the page that holds them.
  defp connected(socket, %User{} = user, agent, kind) do
    track_inline(socket, :inline_connect_completed, agent, kind)
    send(self(), {:agent_connected, user, agent})

    socket
    |> assign(current_user: user, agent: agent, kind: kind, connecting: false)
    |> read_subscription()
    |> read_held()
  end

  defp track_inline(%{assigns: %{scoped_agent: nil}}, _event, _agent, _kind), do: :ok

  defp track_inline(socket, event, agent, kind) do
    Ravix.Analytics.track(socket.assigns.current_user, event, %{
      "ravix.agent" => to_string(agent),
      "ravix.paid_by" => to_string(kind)
    })
  end

  # Something the person held has gone. The choice on the page stays where it
  # was, so what to connect instead is one paste away; the page is told, since
  # projects they own may now have nothing to run on.
  defp disconnected(socket, %User{} = user) do
    send(self(), {:agent_disconnected, user, socket.assigns.disconnecting_agent})

    socket
    |> assign(
      current_user: user,
      held: nil,
      connecting: true,
      credential_form: Form.new(:credential)
    )
    |> read_subscription()
    |> read_held()
  end

  # What the set holds, asked of Fountain off this process. The list is kept
  # while it is asked again, except after removal, when stale connected
  # labels are cleared until the authoritative read completes.
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
    user = socket.assigns.current_user
    traced_async(socket, :subscription, fn -> Inference.subscription(user) end)
  end

  # A sign-in under way is shown however the panel is laid out: in the
  # compact one, that means its card is the one being connected.
  defp show_link(socket, %Inference.Link{} = link),
    do: socket |> assign(link: link, link_error: nil, connecting: true) |> schedule_poll()

  defp schedule_poll(
         %{assigns: %{link: %Inference.Link{poll_interval: seconds}, id: id, poll_token: token}} =
           socket
       ) do
    Process.send_after(self(), {:agent_panel, id, {:poll_link, token}}, seconds * 1000)
    socket
  end

  defp schedule_poll(socket), do: socket

  # ── what the template asks ───────────────────────────────────────────

  defp agent_name(agent), do: Ravix.AgentName.label(to_string(agent))

  defp kind_name(:subscription), do: "Subscription"
  defp kind_name(:api_key), do: "API key"

  # What the connected notice calls it, and what replacing it takes.
  defp paid_by(:codex, :subscription), do: "ChatGPT subscription"
  defp paid_by(_agent, :subscription), do: "subscription"
  defp paid_by(_agent, :api_key), do: "API key"

  defp credential_description(held, agent) when is_list(held) do
    case for {^agent, kind} <- held, do: paid_by(agent, kind) do
      [] -> credential_description(nil, agent)
      kinds -> "Connected with your " <> Enum.join(kinds, " and ") <> "."
    end
  end

  defp credential_description(nil, :claude), do: "Claude subscription or Anthropic API key."
  defp credential_description(nil, :codex), do: "ChatGPT subscription or OpenAI API key."

  # A compact card's one line: what connecting it spends by default. An API
  # key is behind the card's ⋯ menu.
  defp card_description(:claude), do: "Uses your Claude subscription."
  defp card_description(:codex), do: "Uses your ChatGPT subscription."

  # An "already linked" refusal this person can do something about. The other
  # two classifications say what happened and offer no button, because there is
  # nothing here they may press: another Ravix login's subscription is theirs
  # to disconnect, not this page's to take.
  defp resolvable?(%Inference.Conflict{resolution: resolution}),
    do: resolution in [:reconnect, :remove]

  defp resolvable?(_conflict), do: false

  defp conflict_action(:reconnect), do: "Reconnect it"
  defp conflict_action(:remove), do: "Remove the old connection and try again"

  # What an empty submit is told, for the thing this field takes (RAV-134).
  defp empty_message(:claude, :subscription),
    do: "Paste the token from claude setup-token first."

  defp empty_message(_agent, :api_key), do: "Paste your API key first."
  defp empty_message(_agent, _kind), do: "Paste the token or key first."

  # The field's state, as the browser-side hook reads it: an attempt under
  # way, one refused, or neither. Only the change back to `idle` clears what
  # the person pasted.
  defp credential_state(%{pending: :connect}), do: "connecting"

  defp credential_state(%{credential_form: form}),
    do: if(form[:value].errors == [], do: "idle", else: "refused")

  defp credential_errors(form), do: for({message, _opts} <- form[:value].errors, do: message)

  @doc """
  The `phx-remove` for the connect step leaving the page: it folds up rather
  than vanishing, so what is under it moves with it instead of jumping
  (RAV-135). The stylesheet runs the fold, and none under
  prefers-reduced-motion. The new-project form uses it on the wrapper it
  removes, since a removed element's descendants run no `phx-remove` of
  their own.
  """
  def collapse,
    do:
      JS.hide(
        transition: {"agent-collapse", "agent-collapse-from", "agent-collapse-to"},
        time: 220
      )

  defp replace_hint(agent, kind) do
    if Inference.pasted?(agent, kind),
      do: "Paste a new one to replace it",
      else: "Sign in again to reconnect it"
  end

  # Whether this held thing is the one the person's choice names.
  defp in_use?(%User{agent: agent}, agent, _kind), do: true
  defp in_use?(%User{}, _agent, _kind), do: false

  # The row says something pays for the agent; the set, read from Fountain,
  # says it does not. Said only once the set has answered.
  defp missing?(%User{} = user, held) when is_list(held),
    do: Inference.connected?(user) and not connected_agent?(held, user.agent)

  defp missing?(_user, _held), do: false

  defp affected_projects([project]), do: project.name

  defp affected_projects([project | rest]),
    do:
      "#{project.name} and #{length(rest)} other #{if length(rest) == 1, do: "project", else: "projects"}"

  defp remove_confirm(agent, kind) do
    what = "#{agent_name(agent)}'s #{paid_by(agent, kind)}"

    "Remove #{what} from Ravix? This ends your open tracks in every project you own. Projects using #{agent_name(agent)} need another connected #{agent_name(agent)} credential to run again. The #{paid_by(agent, kind)} itself is untouched."
  end

  defp held?(held, agent, kind), do: is_list(held) and {agent, kind} in held

  defp connected_agent?(held, agent) when is_list(held),
    do: Enum.any?(held, fn {a, _} -> a == agent end)

  defp connected_agent?(_held, _agent), do: false

  defp other_agent(held) when is_list(held) do
    case Enum.uniq_by(held, &elem(&1, 0)) do
      [{:claude, _}] -> :codex
      [{:codex, _}] -> :claude
      _ -> nil
    end
  end

  defp other_agent(_held), do: nil

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

  defp subscription_line(assigns) do
    ~H"""
    {describe(@subscription)}
    <%= cond do %>
      <% is_binary(@subscription.exhausted_until) -> %>
        Its plan is spent until
        <.provider_time id="chatgpt-subscription-until" value={@subscription.exhausted_until} />; Codex runs are refused until then.
      <% @subscription.status == "active" -> %>
      <% true -> %>
        Codex runs on your projects are refused until you sign in again.
    <% end %>
    """
  end

  defp describe(%{plan_type: plan, account_email: email}) do
    plan = if is_binary(plan), do: "ChatGPT #{String.capitalize(plan)}", else: "ChatGPT"
    if is_binary(email), do: "#{plan}, #{email}.", else: plan <> "."
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, other_agent: other_agent(assigns.held))

    ~H"""
    <div class={["agent-panel", @compact && "compact"]} id={@id} phx-hook="AgentConfirmation">
      <.missing :if={@compact} held={@held} current_user={@current_user} />
      <div :if={@compact} class="agent-cards" role="group" aria-label="Agents">
        <.card
          :for={agent <- User.agents()}
          agent={agent}
          held={@held}
          current_user={@current_user}
          connecting={@connecting and @agent == agent}
          busy={@busy}
          myself={@myself}
        />
      </div>

      <.thread_default :if={not @compact} {thread_default_assigns(assigns)} />
      <.disconnect_confirmation :if={@disconnect_confirmation} {confirmation_assigns(assigns)} />
      <.loading_status :if={@busy and is_nil(@pending)}>Updating agent connection…</.loading_status>

      <div
        :if={not @compact and is_nil(@scoped_agent)}
        class="agent-choices"
        role="group"
        aria-label="Agent"
      >
        <div :for={agent <- User.agents()}>
          <button
            type="button"
            class={["agent-choice", @agent == agent && "on"]}
            aria-pressed={to_string(@agent == agent)}
            phx-click="choose-agent"
            phx-target={@myself}
            phx-value-agent={agent}
            id={"agent-#{agent}"}
            disabled={@busy}
          >
            <strong>{agent_name(agent)}</strong>
            <small>{credential_description(@held, agent)}</small>
          </button>
          <p id={"agent-#{agent}-status"}>
            <span :if={is_list(@held)}>{if connected_agent?(@held, agent),
              do: "Connected",
              else: "Not connected"}</span>
            <span :if={is_nil(@held)}>Connection status unavailable</span>
            <span :if={@current_user.agent == agent} class="chip">Default for new projects</span>
          </p>
          <button
            :if={connected_agent?(@held, agent) and @current_user.agent != agent}
            type="button"
            class="ghost"
            id={"make-default-#{agent}"}
            phx-click="make-default"
            phx-value-agent={agent}
            phx-target={@myself}
            disabled={@busy}
          >
            Make default
          </button>
        </div>
      </div>

      <section
        :if={not @compact and is_nil(@scoped_agent) and @other_agent}
        id="second-agent-nudge"
        class="agent-held"
      >
        <strong>{if @onboarding,
          do: "Connect #{agent_name(@other_agent)} too (optional)",
          else: "Also connect #{agent_name(@other_agent)}"}</strong>
        <p class="hint">Choose the agent that fits each project without changing your default.</p>
        <button
          type="button"
          class="ghost"
          id="connect-second-agent"
          phx-click="choose-agent"
          phx-target={@myself}
          phx-value-agent={@other_agent}
          disabled={@busy}
        >Set up {agent_name(@other_agent)}</button>
      </section>

      <.held :if={not @compact} {held_assigns(assigns)} />

      <div
        :if={@agent && (not @compact or @connecting)}
        class="agent-connect"
        id="agent-connect"
        phx-remove={collapse()}
      >
        <div class="agent-credential" role="group" aria-labelledby="agent-connect-title">
          <p class="agent-connect-title" id="agent-connect-title">Connect {agent_name(@agent)}</p>
          <.kinds :if={not @compact} agent={@agent} kind={@kind} busy={@busy} myself={@myself} />
          <.credential {credential_assigns(assigns)} />
        </div>
      </div>

      <div
        :if={
          (@compact and is_nil(@scoped_agent) and @thread_defaults) && @thread_defaults.choices != []
        }
        class="agent-manage"
      >
        <button
          type="button"
          class="ghost agent-manage-toggle"
          id="agent-manage-toggle"
          aria-expanded={to_string(@manage_open)}
          aria-controls="agent-manage"
          phx-click="toggle-manage"
          phx-target={@myself}
        >
          <.icon name="chevron" size={12} open={@manage_open} />Default model for new threads
        </button>
        <div id="agent-manage" hidden={!@manage_open}>
          <.thread_default {thread_default_assigns(assigns)} />
        </div>
      </div>
    </div>
    """
  end

  # The pieces both layouts draw. Passed only what each reads, so a change to
  # one assign re-renders only the piece that shows it.
  defp thread_default_assigns(assigns),
    do:
      Map.take(assigns, [
        :scoped_agent,
        :thread_defaults,
        :busy,
        :thread_default_saved,
        :thread_default_error,
        :myself
      ])

  defp confirmation_assigns(assigns), do: Map.take(assigns, [:disconnect_confirmation, :myself])

  defp held_assigns(assigns),
    do: Map.take(assigns, [:scoped_agent, :held, :current_user, :busy, :myself])

  defp credential_assigns(assigns),
    do:
      Map.take(assigns, [
        :agent,
        :kind,
        :held,
        :subscription,
        :link,
        :link_error,
        :link_conflict,
        :linking,
        :credential_form,
        :busy,
        :pending,
        :myself
      ])

  defp thread_default(assigns) do
    ~H"""
    <form
      :if={is_nil(@scoped_agent) && @thread_defaults && @thread_defaults.choices != []}
      id="thread-default-form"
      phx-submit="save-thread-default"
      phx-change="change-thread-default"
      phx-target={@myself}
    >
      <div class="thread-default-copy">
        <label for="thread-default-choice">Default agent for new threads</label>
        <p>
          Used when the project's payer has connected this agent. Existing threads keep their agent.
        </p>
      </div>
      <div class="thread-default-controls">
        <select id="thread-default-choice" name="preference[choice]" disabled={@busy}>
          <option
            :for={choice <- @thread_defaults.choices}
            value={choice.runtime <> "|" <> choice.model}
            selected={choice == @thread_defaults.preference}
          >
            {RavixWeb.AgentName.label(choice.runtime)} · {RavixWeb.ModelName.friendly(choice.model)}
          </option>
        </select>
        <button type="submit" disabled={@busy}>Save thread default</button>
      </div>
      <p :if={@thread_default_saved} role="status">Thread default saved.</p>
      <p :if={@thread_default_error} role="alert">{@thread_default_error}</p>
    </form>
    """
  end

  defp disconnect_confirmation(assigns) do
    ~H"""
    <div id="agent-disconnect-confirmation" role="group" aria-label="Confirm agent removal">
      <p>{remove_confirm(@disconnect_confirmation.agent, @disconnect_confirmation.kind)}</p>
      <p :if={@disconnect_confirmation.projects != []}>
        {affected_projects(@disconnect_confirmation.projects)} use {agent_name(
          @disconnect_confirmation.agent
        )} and will stop working unless another credential for this agent remains connected.
      </p>
      <ul aria-label="Affected projects">
        <li :for={project <- @disconnect_confirmation.projects}>{project.name}</li>
      </ul>
      <button
        type="button"
        id="confirm-agent-disconnect"
        class="primary"
        phx-click="confirm-disconnect"
        phx-target={@myself}
        phx-mounted={JS.focus()}
      >Remove connection</button>
      <button type="button" phx-click="cancel-disconnect" phx-target={@myself}>Cancel</button>
    </div>
    """
  end

  attr :scoped_agent, :atom
  attr :held, :any
  attr :current_user, User
  attr :busy, :boolean
  attr :myself, :any

  defp held(assigns) do
    ~H"""
    <section
      :if={
        is_nil(@scoped_agent) and is_list(@held) and (@held != [] or missing?(@current_user, @held))
      }
      class="agent-held"
      id="agent-held"
      aria-label="What you have connected"
    >
      <.missing held={@held} current_user={@current_user} />
      <ul :if={@held != []} class="agent-held-list">
        <li :for={{agent, kind} <- @held} id={"held-#{agent}-#{kind}"}>
          <span class="agent-held-name">
            <strong>{agent_name(agent)}</strong>
            <span class="dim">{paid_by(agent, kind)}</span>
            <span :if={in_use?(@current_user, agent, kind)} class="chip ok">Default for new projects</span>
          </span>
          <button
            type="button"
            class="ghost"
            phx-click="disconnect"
            phx-target={@myself}
            phx-value-agent={agent}
            phx-value-kind={kind}
            disabled={@busy}
            id={"remove-#{agent}-#{kind}"}
          >
            Remove
          </button>
        </li>
      </ul>
      <p :if={@held != []} class="hint">
        Removing or replacing a connection ends your open tracks. Your provider account stays active.
      </p>
    </section>
    """
  end

  attr :held, :any
  attr :current_user, User

  defp missing(assigns) do
    ~H"""
    <p :if={missing?(@current_user, @held)} class="welcome-warning" id="held-missing">
      <.icon name="info" size={14} class="ico" />
      <span>
        Nothing is stored for {agent_name(@current_user.agent)} any more: its subscription or API key was removed outside this page. Projects using this agent need a connected credential to run.
      </span>
    </p>
    """
  end

  attr :agent, :atom, required: true
  attr :held, :any, required: true
  attr :current_user, User, required: true
  attr :connecting, :boolean, required: true
  attr :busy, :boolean, required: true
  attr :myself, :any, required: true

  # One compact card (RAV-77): Connect, or ✓ Connected with Make default,
  # and the rest -- another way to pay, replacing, removing -- behind its
  # ⋯ menu. Nothing here warns about open tracks: replacing says so in the
  # steps it opens, and removing in its confirmation, which is when it is
  # about to happen.
  defp card(assigns) do
    assigns =
      assign(assigns,
        connected: connected_agent?(assigns.held, assigns.agent),
        default: assigns.current_user.agent == assigns.agent,
        kinds: Inference.kinds(assigns.agent)
      )

    ~H"""
    <div
      id={"agent-card-#{@agent}"}
      class={[
        "agent-card",
        @connected && "connected",
        @connected && @default && "default",
        @connecting && "on"
      ]}
    >
      <div class="agent-card-head">
        <strong>{agent_name(@agent)}</strong>
        <RavixWeb.Live.ModelMenu.chip
          id={"agent-menu-#{@agent}"}
          label={"More for #{agent_name(@agent)}"}
          data-tip={"More for #{agent_name(@agent)}"}
          title=""
          menu_label={agent_name(@agent)}
          class="ghost agent-card-more"
          menu_class="chip-popover-below chip-popover-end agent-card-menu"
          disabled={@busy}
        >
          <:trigger><.icon name="more" size={16} /></:trigger>
          <%= for kind <- @kinds do %>
            <button
              type="button"
              role="menuitem"
              class="account-item"
              id={"connect-#{@agent}-#{kind}"}
              phx-click="connect-with"
              phx-value-agent={@agent}
              phx-value-kind={kind}
              phx-target={@myself}
              data-chip-close
            >
              {connect_label(@held, @agent, kind)}
            </button>
            <button
              :if={held?(@held, @agent, kind)}
              type="button"
              role="menuitem"
              class="account-item danger"
              id={"remove-#{@agent}-#{kind}"}
              phx-click="disconnect"
              phx-value-agent={@agent}
              phx-value-kind={kind}
              phx-target={@myself}
              data-chip-close
            >
              Remove your {paid_by(@agent, kind)}
            </button>
          <% end %>
        </RavixWeb.Live.ModelMenu.chip>
      </div>
      <small>
        {if @connected, do: credential_description(@held, @agent), else: card_description(@agent)}
      </small>
      <p id={"agent-#{@agent}-status"} class="agent-card-status">
        <span :if={@connected} class="agent-card-connected">
          <.icon name="check" size={13} class="ico" />Connected
        </span>
        <span :if={@connected and @default} class="chip">Default for new projects</span>
        <span :if={is_nil(@held)} class="dim">Checking…</span>
      </p>
      <button
        :if={not @connected and not @connecting}
        type="button"
        class={if is_nil(@current_user.agent), do: "primary", else: "ghost"}
        phx-click="choose-agent"
        phx-target={@myself}
        phx-value-agent={@agent}
        id={"agent-#{@agent}"}
        aria-label={"Connect #{agent_name(@agent)}"}
        disabled={@busy}
      >
        Connect
      </button>
      <button
        :if={@connected and not @default}
        type="button"
        class="ghost"
        id={"make-default-#{@agent}"}
        phx-click="make-default"
        phx-value-agent={@agent}
        phx-target={@myself}
        aria-label={"Make #{agent_name(@agent)} the default for new projects"}
        disabled={@busy}
      >
        Make default
      </button>
      <span :if={@connecting} class="dim agent-card-hint">
        Follow the steps below
      </span>
    </div>
    """
  end

  # A card menu's item for one way of paying: connect with it, or replace
  # the one held. Replacing ends open tracks; the steps it opens say so.
  defp connect_label(held, agent, kind) do
    cond do
      held?(held, agent, kind) and Inference.pasted?(agent, kind) ->
        "Replace your #{paid_by(agent, kind)}"

      held?(held, agent, kind) ->
        "Reconnect your #{paid_by(agent, kind)}"

      kind == :api_key ->
        "Connect with an API key"

      true ->
        "Connect with a subscription"
    end
  end

  defp kinds(assigns) do
    ~H"""
    <div class="workspace-actions agent-payment-methods" role="group" aria-label="How it is paid for">
      <button
        :for={kind <- Inference.kinds(@agent)}
        type="button"
        class={if @kind == kind, do: "primary", else: "ghost"}
        aria-pressed={to_string(@kind == kind)}
        phx-click="choose-kind"
        phx-target={@myself}
        phx-value-kind={kind}
        id={"kind-#{kind}"}
        disabled={@busy}
      >
        {kind_name(kind)}
      </button>
    </div>
    """
  end

  defp credential(assigns) do
    ~H"""
    <p
      :if={is_list(@held) and {@agent, @kind} in @held}
      class="welcome-connected"
      id="welcome-connected"
    >
      <.icon name="check" size={14} class="ico" />
      <span>
        {agent_name(@agent)} is connected with your {paid_by(@agent, @kind)}. {replace_hint(
          @agent,
          @kind
        )}. Replacing it ends your open tracks in every project you own. A conversation will not carry on with a different credential than it started with.
      </span>
    </p>

    <p
      :if={@agent == :codex && @subscription}
      class="agent-subscription"
      id="chatgpt-subscription"
    >
      <span class={["chip", subscription_tone(@subscription)]}>{subscription_state(@subscription)}</span>
      <span><.subscription_line subscription={@subscription} /></span>
    </p>

    <ol :if={@agent == :claude && @kind == :subscription} class="agent-howto">
      <li>
        In a signed-in Claude Code terminal, run <code>claude setup-token</code>.
      </li>
      <li>Approve in your browser.</li>
      <li>Paste the token beginning with <code>sk-ant-oat01-</code>.</li>
    </ol>
    <ol :if={@agent == :claude && @kind == :api_key} class="agent-howto">
      <li>
        Create a key in the Anthropic Console, under <strong>API keys</strong>.
      </li>
      <li>
        Paste it here. It starts with <code>sk-ant-api</code>. API usage is billed separately.
      </li>
    </ol>
    <ol :if={@agent == :codex && @kind == :api_key} class="agent-howto">
      <li>
        Create a key on the OpenAI platform, under <strong>API keys</strong>.
      </li>
      <li>
        Paste it here. It starts with <code>sk-</code>. API usage is billed separately.
      </li>
    </ol>

    <div :if={@agent == :codex && @kind == :subscription} id="chatgpt-link">
      <ol class="agent-howto">
        <li>
          Press <strong>Connect ChatGPT</strong> for a one-time code.
        </li>
        <li>
          Enter it in a browser signed in to the ChatGPT account whose plan should pay.
        </li>
        <li>This page notices the approval and moves on.</li>
      </ol>
      <p :if={@link_error} class="error" id="link-error" role="alert">{@link_error}</p>
      <div
        :if={resolvable?(@link_conflict)}
        class="workspace-actions"
        id="chatgpt-conflict"
      >
        <button
          type="button"
          class="primary"
          phx-click="resolve-conflict"
          phx-target={@myself}
          disabled={@busy}
          id="chatgpt-resolve-conflict"
        >{conflict_action(@link_conflict.resolution)}</button>
      </div>
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
          >{@link.verification_url}</a><code :if={!@link.trusted?} id="chatgpt-verification">{@link.verification_url}</code>. This authorizes use of your ChatGPT plan. Only type it if you started this sign-in yourself, on this page, just now. Nobody at Ravix will ever send you a code.
        </p>
        <p class="hint">
          Waiting for approval. This code expires in 15 minutes.
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
      <div :if={is_nil(@link) && @linking != false} class="agent-connect-actions">
        <.busy_button
          id="chatgpt-connect"
          type="button"
          phx-click="begin-link"
          phx-target={@myself}
          disabled={@busy}
          busy={@pending == :begin_link}
          busy_label="Asking ChatGPT…"
        >
          Connect ChatGPT
        </.busy_button>
      </div>
      <p class="hint">
        Credentials stay encrypted with the agent service and are never shown — not to you, not to teammates, and not on this page. Disconnecting Ravix does not sign you out of ChatGPT.
      </p>
    </div>

    <%!-- `novalidate`: an empty submit reaches the server and is refused on
      the field (RAV-134); the browser's own bubble covered the hint and
      stayed until the next click. The input is `phx-update="ignore"` so the
      paste survives every patch until the attempt is over; the hook applies
      what the server says about it from its data attributes. --%>
    <.form
      :if={Inference.pasted?(@agent, @kind)}
      for={@credential_form}
      id="credential-form"
      phx-submit="connect"
      phx-target={@myself}
      autocomplete="off"
      novalidate
    >
      <div class="field">
        <label for="credential-value">
          {if @kind == :subscription, do: "Subscription token", else: "API key"}
        </label>
        <input
          type="password"
          name="credential[value]"
          id="credential-value"
          autocomplete="off"
          spellcheck="false"
          aria-describedby="credential-value-error credential-value-hint"
          aria-invalid={credential_errors(@credential_form) != [] && "true"}
          disabled={@busy}
          phx-update="ignore"
          phx-hook="CredentialField"
          data-state={credential_state(assigns)}
          data-disabled={to_string(@busy)}
          data-invalid={to_string(credential_errors(@credential_form) != [])}
        />
        <div id="credential-value-error" aria-live="polite">
          <p :for={message <- credential_errors(@credential_form)} class="error fine">{message}</p>
        </div>
        <p class="hint" id="credential-value-hint">
          Stored encrypted with the agent service. Never displayed or shared with teammates.
        </p>
      </div>
      <div class="agent-connect-actions">
        <span class="sr-only" role="status" id="credential-status">{if @pending == :connect,
          do: "Connecting #{agent_name(@agent)}…"}</span>
        <.busy_button
          id="credential-submit"
          disabled={@busy}
          busy={@pending == :connect}
          busy_label="Connecting…"
        >
          Connect {agent_name(@agent)}
        </.busy_button>
      </div>
    </.form>
    """
  end

  attr :busy, :boolean, required: true
  attr :busy_label, :string, required: true
  attr :rest, :global, include: ~w(disabled type)
  slot :inner_block, required: true

  # A button that shows its own progress in the width it already had: both
  # labels are drawn in the same cell and one is hidden, so the box never
  # moves under the pointer that pressed it (RAV-135). The hidden label is
  # out of the accessible name as well, so the button reads as whichever
  # label is showing and never both; the sr-only status beside the connect
  # form is what announces the wait.
  defp busy_button(assigns) do
    ~H"""
    <button class="agent-connect-submit" aria-busy={to_string(@busy)} {@rest}>
      <span class="agent-connect-label" aria-hidden={to_string(@busy)}>
        {render_slot(@inner_block)}
      </span>
      <span class="agent-connect-busy" aria-hidden={to_string(not @busy)}>
        <span class="loading-spinner" aria-hidden="true"></span>{@busy_label}
      </span>
    </button>
    """
  end
end
