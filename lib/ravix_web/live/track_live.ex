defmodule RavixWeb.TrackLive do
  @moduledoc "One track's transcript, composer, sharing, and machine panels."
  use RavixWeb, :live_view
  on_mount {RavixWeb.Live.Hooks, :require_authenticated_user}

  # The browser's words for the tabs and the dialogs, and Ravix's. Fixed
  # tables, guarded with `is_map_key/2`, so the conversion happens once at
  # the boundary, nothing past it compares strings, and a name nobody
  # declared matches no clause -- exactly as the `in ~w(...)` guards these
  # replace behaved.
  @tabs %{"files" => :files, "changes" => :changes, "checks" => :checks, "preview" => :preview}
  @dialogs %{
    "rename" => :rename,
    "close" => :close,
    "rebuild" => :rebuild,
    "people" => :people,
    "pull" => :pull,
    "commit" => :commit
  }

  # How often the page re-reads everything without being told to.
  #
  # This is a backstop and nothing else. Ravix runs on more than one instance
  # (ADR 0003) and PubSub is best-effort, so a partition can eat the hub event
  # that would have refreshed the ribbon or the queue; the tick is what closes
  # that gap. Everything it covers already arrives on its own: turns and
  # queue movements on the project's hub, transcript events from the track's
  # `Ravix.Tracks.Follower`.
  #
  # It was fifteen seconds, which is the interval of a primary update path
  # rather than a backstop, and it made every open page --- including one
  # nobody was looking at --- cost two Fountain reads and a transcript read
  # four times a minute. `RavixWeb.Live.Guard` keeps its own fifteen because
  # what it backstops is somebody's access being revoked.
  @refresh_ms 60_000

  # How long the page lets transcript events pile up before it draws them.
  #
  # Fountain's stream is token-granularity --- an ACP `session/update` carries
  # a few characters of the reply, and `Ravix.Tracks.Follower` broadcasts every
  # one of them --- so "draw what just arrived" ran tens of times a second per
  # reader. Each of those runs re-rendered the *whole* turn: `stream_insert/4`
  # keeps no fingerprint for a stream item (it is what makes a stream cost no
  # server memory), so the entire rendered turn goes over the socket every
  # time, markdown and pretty-printed tool input included. The cost of drawing
  # one token was therefore the size of the turn so far, and a long turn spent
  # the whole of itself paying it.
  #
  # A tenth of a second is under the threshold where text stops looking like
  # it is being typed and starts looking like it is arriving in blocks, and it
  # bounds the work at ten renders a second however fast the agent talks. The
  # events themselves are still laid into `page` as they arrive: what is
  # deferred is the drawing, not the reading, so nothing is lost if the page
  # is closed mid-flush.
  @flush_ms 100

  # How long the composer's `@` trusts the file list it read. See
  # `handle_event("mention-files", ...)`.
  @file_index_ms 30_000

  alias Ravix.Accounts.Access
  alias Ravix.Comments
  alias Ravix.GitHub.ChecksReport
  alias Ravix.{Hub, Previews, PromptQueue, SessionConfig, Terminal, Tracks}
  alias Ravix.Hub.Event
  alias Ravix.Tracks.{AgentFailure, Diff, Files, Follower, MachineState, Track}
  alias Ravix.Tracks.Transcript
  alias Ravix.Tracks.Transcript.Block, as: TranscriptBlock
  alias Ravix.Tracks.Transcript.Commands
  alias Ravix.Tracks.Transcript.Event, as: TranscriptEvent
  alias RavixWeb.Error
  alias RavixWeb.Live.Form
  alias RavixWeb.Live.Guard
  alias RavixWeb.Live.MachineDock
  alias RavixWeb.Live.ModelMenu
  alias RavixWeb.Live.Panel
  alias RavixWeb.Live.Params
  alias RavixWeb.Live.ThreadConnect
  alias RavixWeb.Live.ToolCall
  alias RavixWeb.Markdown

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) and Ravix.Config.dedicated_rollout?(),
      do: Phoenix.PubSub.subscribe(Ravix.PubSub, "inference:credentials")

    socket =
      assign(socket,
        track_id: session["track_id"],
        thread_id: session["track_id"],
        # The zone the browser reported to the workspace on connect, for the
        # server's reading of timestamps before `LocalTime` rewrites them.
        timezone: Ravix.Schedules.timezone(session["timezone"]),
        thread_generation: 0,
        threads: [],
        sibling_followers: %{},
        thread_states: %{},
        # What the tabs, Stop, the machine and Checks say of the turns
        # (RAV-91); see `assign_turn/1`.
        turn: %{states: %{}, running?: false, working?: false, machine: nil},
        # The "+" tab: a thread nobody has sent anything to yet. It lives in
        # this page and nowhere else --- a reload drops it, and nobody else
        # on the track ever sees it. See `show_draft/1` and `start/2`.
        thread_draft: nil,
        thread_connect: nil,
        thread_error: nil,
        # The thread whose tab is a rename field now (RAV-97), or nil.
        thread_renaming: nil,
        # The running thread whose close is waiting on its confirmation.
        thread_closing: nil,
        # Whether the composer's box is empty, as its `Composer` hook last
        # said (`composer-draft`): the text itself stays in the browser.
        composer_empty?: true,
        # The creator's one-time note that collaborators' prompts spend their
        # subscription (ADR 0009 phase 6); see `Tracks.billing_notice/2`.
        billing_notice: nil,
        project_id: session["project_id"],
        agent_refused: false,
        health_refresh: 0,
        track: nil,
        project: nil,
        header: nil,
        assigned_plan: %{items: [], plan: nil},
        starters: [],
        # The models the composer's menu offers, for the project's runtime.
        # Empty when the catalog could not be read: the model is then shown
        # without a menu.
        models: [],
        page: Transcript.empty(""),
        # The markdown of every block on the page, rendered once per body.
        # See `memoize/1`.
        rendered: %{},
        loading: true,
        # The transcript is read separately from the rest of the track, and
        # is the slowest of the reads, so the page says which of the two it
        # is still waiting on rather than treating "loaded" as one moment.
        transcript_loading: true,
        earlier_loading: false,
        # How far the transcript *reads* have got, which `page.last_event_id`
        # is not: live events move that one on, including past an event this
        # page never received. See `catch_up_transcript/1`.
        read_through: nil,
        queue: [],
        present: [],
        narrow_view: "conversation",
        panel: Panel.new(),
        show_ignored?: false,
        branch_merged?: false,
        diff_path: nil,
        diff_filter: "",
        diff_show_large: false,
        # Whether this deployment can serve previews at all (RAV-42). The
        # header's Preview control is not drawn on one that cannot, and the
        # page does not read the track's preview for it.
        previews?: Previews.unavailable() == nil,
        preview: nil,
        preview_form: Form.new(:preview_config),
        preview_url: nil,
        # The preview button pressed and not yet answered ("run", "open"...),
        # so it says so at once rather than when the answer lands.
        preview_pending: nil,
        # Whether this page asked to open the preview and is waiting for it
        # to be ready. The ticket the click minted is good for a minute, and a
        # wake and a start can take longer, so a fresh one is minted then.
        preview_opening?: false,
        dialog: nil,
        close_info: nil,
        rename_form: Form.new(:rename_track),
        pull: nil,
        # The Checks tab's Git status: `nil` until read, then
        # `%{status: Git.Status.t() | nil, error: String.t() | nil}`. A commit
        # or push out is `:git` in `pending`; `git_step` says which, and
        # `git_failure` is the last one's refusal, kept until the next try.
        git: nil,
        git_loading?: false,
        git_step: nil,
        git_failure: nil,
        commit_message: "",
        # The ribbon's three writes that are out --- `:interrupt`, `:retry`,
        # `:pull` --- each disabling the button that would repeat it. See
        # `begin/3`.
        pending: MapSet.new(),
        attached_images: [],
        # People's comments on the shown thread, oldest first, and which one
        # its author is editing. Never sent to the agent; see `Ravix.Comments`.
        comments: [],
        comment_editing: nil,
        # What the composer sends: a prompt to the agent (`:ask`) or a comment
        # for people (`:comment`), and who a comment there can @-mention.
        composer_mode: :ask,
        mentionable: [],
        # The slash commands the shown thread's agent advertised (ACP
        # `available_commands_update`), newest list wins. See `absorb/2`.
        agent_commands: [],
        # The track's files for the composer's `@`, read on the first `@` and
        # kept briefly: `%{track_id:, index:, at:}`, or nil. See
        # `file_index/1`.
        file_index: nil,
        file_index_loading?: false,
        # The turns that have taken an event since the last time the page drew,
        # and whether any of those events ended a stage. See `absorb/2`.
        dirty_turns: MapSet.new(),
        stage_seen?: false,
        flushing?: false,
        # What the polite live region under the transcript says. A reader who
        # is not looking --- a screen reader, or somebody scrolled up in a long
        # transcript --- hears nothing from tokens streaming in, so the one
        # moment worth a word is a turn ending. See `absorb/2`.
        announcement: nil,
        # The monitor reference for this page's transcript follower, if it has
        # one. See `follow/2`.
        follower: nil,
        # Whether this person still reaches this track, and when that has to
        # be asked again. See `guard/2`.
        track_guard: nil,
        # What the dock's passive probe last found for this track's machine
        # (`Ravix.Terminal.status/3`), with the sleep the row recorded when it
        # answered, or nil before it does. See `probed/2`.
        machine_probe: nil,
        setup_now: DateTime.utc_now()
      )

    if authorized?(socket) do
      socket =
        socket
        |> allow_upload(:images,
          accept: ~w(.png .jpg .jpeg .gif .webp),
          auto_upload: true,
          max_entries: 6,
          max_file_size: 8 * 1024 * 1024
        )
        |> stream(:turns, [])
        |> assign(track_guard: renew(socket))
        |> attach_hook(:track_event_access, :handle_event, fn _, _, s -> guard(s) end)
        |> attach_hook(:track_message_access, :handle_info, &guard(&2, &1))
        |> attach_hook(:track_async_access, :handle_async, fn _, _, s -> guard(s) end)

      if connected?(socket) do
        Hub.subscribe(socket.assigns.project_id)
        Previews.subscribe(socket.assigns.current_user, socket.assigns.track_id)
        Process.send_after(self(), :refresh, @refresh_ms)
        Process.send_after(self(), :setup_clock, 1_000)
        announce(socket)
      end

      {:ok, if(connected?(socket), do: load(socket), else: socket)}
    else
      {:ok, redirect(socket, to: "/")}
    end
  end

  # A terminal's keystrokes and size, from the `Shell` hook. They come to the
  # page rather than to `RavixWeb.Live.MachineDock` so that the page's guard,
  # which reads nothing while its answer stands, is what stands in front of
  # them: a component event re-reads the session row, and a keystroke should
  # not cost a query. `Ravix.Terminal` reaches only a shell this very process
  # attached, and the shell watches the session and the track itself.
  @impl true
  def handle_event("shell-input", %{"id" => id, "data" => data}, socket)
      when is_binary(id) and is_binary(data) do
    Terminal.input(id, data)
    {:noreply, socket}
  end

  def handle_event("shell-resize", %{"id" => id, "cols" => cols, "rows" => rows}, socket)
      when is_binary(id) do
    Terminal.resize(id, cols, rows)
    {:noreply, socket}
  end

  def handle_event("select-thread", %{"thread_id" => "draft"}, socket),
    do: {:noreply, show_draft(socket)}

  def handle_event("select-thread", %{"thread_id" => id}, socket) do
    shown = if drafting?(socket), do: nil, else: socket.assigns.thread_id

    case Access.thread_access(socket.assigns.current_user, socket.assigns.track_id, id) do
      # The selected tab is still a button; pressing it again keeps the
      # transcript and the follower it already has.
      {:ok, _} when id == shown ->
        {:noreply, socket}

      {:ok, _} ->
        {:noreply, switch_thread(socket, id)}

      {:error, reason} ->
        {:noreply, error(socket, reason)}
    end
  end

  # RAV-97: a tab's title becomes a field in place (a double-click, F2, or
  # the thread's ⋯). Saving is only for the thread still being renamed, so
  # the blur that follows Enter or Escape, arriving after it, does nothing.
  def handle_event("edit-thread-title", %{"thread_id" => id}, socket) when is_binary(id) do
    case Access.thread_access(socket.assigns.current_user, socket.assigns.track_id, id, :write) do
      {:ok, _} -> {:noreply, assign(socket, thread_renaming: id)}
      {:error, reason} -> {:noreply, error(socket, reason)}
    end
  end

  def handle_event(
        "rename-thread",
        %{"thread_id" => id, "title" => title},
        %{assigns: %{thread_renaming: id}} = socket
      )
      when is_binary(title) do
    title = String.trim(title)
    shown = Enum.find(shown_threads(socket.assigns), &(&1.id == id))

    if title == "" or (shown && shown.title == title) do
      {:noreply, assign(socket, thread_renaming: nil)}
    else
      case Tracks.rename_thread(socket.assigns.current_user, socket.assigns.track_id, id, title) do
        :ok ->
          {:noreply,
           socket
           |> assign(thread_renaming: nil)
           |> update(:threads, fn threads ->
             Enum.map(threads, &if(&1.id == id, do: %{&1 | title: title}, else: &1))
           end)}

        {:error, reason} ->
          {:noreply, socket |> assign(thread_renaming: nil) |> error(reason)}
      end
    end
  end

  def handle_event("rename-thread", _, socket), do: {:noreply, socket}

  def handle_event("cancel-thread-rename", _, socket),
    do: {:noreply, assign(socket, thread_renaming: nil)}

  # RAV-97: a tab's × (or ⋯ › Close thread, or Delete on the tab) archives
  # the thread. One that is running asks first; `confirmed` is the dialog's
  # answer. The shown thread gives way to its neighbour.
  def handle_event("close-thread", %{"thread_id" => id} = params, socket) when is_binary(id) do
    running? =
      Enum.any?(socket.assigns.threads, fn thread ->
        thread.id == id and tab_status(thread, socket.assigns.turn.states) == "Running"
      end)

    cond do
      # A second click on a × whose thread has already gone.
      not Enum.any?(socket.assigns.threads, &(&1.id == id)) ->
        {:noreply, socket}

      running? and params["confirmed"] != "true" ->
        {:noreply, assign(socket, dialog: :close_thread, thread_closing: id)}

      true ->
        case Tracks.close_thread(socket.assigns.current_user, socket.assigns.track_id, id) do
          :ok -> {:noreply, closed_thread(socket, id)}
          {:error, reason} -> {:noreply, socket |> assign(dialog: nil) |> error(reason)}
        end
    end
  end

  def handle_event("dismiss-billing-notice", _, socket),
    do: {:noreply, assign(socket, billing_notice: nil)}

  def handle_event("connect-thread-agent", %{"runtime" => runtime}, socket) do
    connection =
      ThreadConnect.open(
        socket.assigns.current_user,
        socket.assigns.project_id,
        runtime,
        socket.assigns.thread_draft && socket.assigns.thread_draft.options
      )

    {:noreply, assign(socket, thread_connect: connection)}
  end

  # "+": a draft tab on the person's default agent and model, and nothing
  # else. The thread itself is made by the first message; see `start/2`.
  # Pressing it again goes back to the draft there is rather than making a
  # second one.
  def handle_event("draft-thread", _, %{assigns: %{thread_draft: nil}} = socket) do
    draft = %{
      id: Ecto.UUID.generate(),
      selected?: false,
      options: nil,
      runtime: nil,
      model: nil,
      source: nil,
      explicit?: false
    }

    {:noreply,
     socket
     |> assign(thread_draft: draft, thread_error: nil)
     |> show_draft()
     |> draft_options()}
  end

  def handle_event("draft-thread", _, socket) do
    socket = show_draft(socket)

    if socket.assigns.thread_draft.options,
      do: {:noreply, socket},
      else: {:noreply, draft_options(socket)}
  end

  def handle_event("discard-draft", _, %{assigns: %{thread_draft: %{} = draft}} = socket) do
    socket =
      socket
      |> cancel_async(:thread_options)
      |> settle(:thread_options)
      |> assign(thread_draft: nil, thread_connect: nil, thread_error: nil)
      |> push_event("composer:forget", %{key: draft_key(socket.assigns.track_id, draft)})

    if draft.selected?,
      do: {:noreply, switch_thread(socket, socket.assigns.thread_id)},
      else: {:noreply, socket}
  end

  def handle_event("discard-draft", _, socket), do: {:noreply, socket}

  def handle_event("narrow-view", %{"name" => name}, socket)
      when name in ["conversation", "files", "terminal"] do
    if name == "terminal" do
      send_update(MachineDock, id: "machine-dock-panel", dock_open: true)
    end

    {:noreply, assign(socket, narrow_view: name)}
  end

  def handle_event("narrow-view", _, socket), do: {:noreply, socket}

  def handle_event("load-earlier", _, socket) do
    page = socket.assigns.page

    if socket.assigns.earlier_loading or not Transcript.History.more?(page.history) do
      {:noreply, socket}
    else
      user = socket.assigns.current_user
      track_id = socket.assigns.track_id
      thread_id = socket.assigns.thread_id
      key = {:earlier, thread_id, socket.assigns.thread_generation, history_cursor(page)}
      history = Transcript.History.request(page.history)

      {:noreply,
       socket
       |> assign(earlier_loading: true)
       |> traced_async(key, fn ->
         Tracks.earlier_events(user, track_id, history, thread_id: thread_id)
       end)}
    end
  end

  def handle_event("retry-load", _, socket), do: {:noreply, load(socket)}

  # The draft's agent and model live in the composer's own form, so a change
  # to either arrives here. Either is an explicit pick (RAV-7): sending
  # remembers it as this person's default for new threads.
  def handle_event("validate", %{"thread_draft" => picks} = params, socket) do
    case {socket.assigns.thread_draft, params["_target"]} do
      {%{options: %{}} = draft, ["thread_draft", field]} when field in ["runtime", "model"] ->
        runtime = if field == "runtime", do: picks["runtime"], else: draft.runtime
        model = if field == "model", do: picks["model"]
        {:noreply, assign(socket, thread_draft: pick(%{draft | explicit?: true}, runtime, model))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("validate", _, socket), do: {:noreply, socket}

  def handle_event("typing", _, socket) do
    Tracks.beat(socket.assigns.current_user, socket.assigns.track_id, :typing)
    {:noreply, socket}
  end

  # RAV-87: the `Composer` hook says when its box turns empty or not, and
  # only then, so send is disabled with nothing to send and steps aside for
  # Stop while a turn runs. Nothing else is read from it.
  def handle_event("composer-draft", %{"empty" => empty}, socket) when is_boolean(empty),
    do: {:noreply, assign(socket, composer_empty?: empty)}

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :images, ref)}

  def handle_event("clear-attachments", _, socket),
    do: {:noreply, assign(socket, attached_images: [])}

  # Comment mode sends to people, never to the agent: nothing here reaches
  # `Tracks.prompt/3`, and any images waiting in the composer stay for the
  # next prompt.
  def handle_event("send", %{"text" => text}, %{assigns: %{composer_mode: :comment}} = socket),
    do: post_comment(socket, text)

  def handle_event("send", %{"text" => text}, socket) do
    {complete, pending} = uploaded_entries(socket, :images)

    cond do
      pending != [] ->
        {:noreply, flash(socket, :error, "Wait for the images to finish uploading.")}

      length(complete) + length(socket.assigns.attached_images) > 6 ->
        {:noreply, flash(socket, :error, "Attach at most six images.")}

      upload_errors(socket.assigns.uploads.images) != [] ->
        {:noreply, flash(socket, :error, "Remove invalid images before sending.")}

      drafting?(socket) ->
        {:noreply, start(socket, text)}

      true ->
        send_prompt(socket, text)
    end
  end

  def handle_event("composer-mode", %{"mode" => "comment"}, socket) do
    if drafting?(socket),
      do: {:noreply, socket},
      else: {:noreply, comment_mode(socket)}
  end

  def handle_event("composer-mode", _, socket),
    do: {:noreply, assign(socket, composer_mode: :ask)}

  # Only the author's own comment opens for editing; the component checks
  # authorship again, and `Comments.edit/4` refuses anybody else regardless.
  def handle_event("edit-comment", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    if Enum.any?(socket.assigns.comments, &(&1.id == id and &1.author_id == user_id)),
      do: {:noreply, socket |> assign(comment_editing: id) |> redraw_comments([id])},
      else: {:noreply, socket}
  end

  def handle_event("cancel-comment-edit", _, socket) do
    editing = socket.assigns.comment_editing
    {:noreply, socket |> assign(comment_editing: nil) |> redraw_comments([editing])}
  end

  def handle_event("save-comment", %{"comment_id" => id, "body" => body}, socket) do
    user = socket.assigns.current_user

    {:noreply,
     result(socket, Comments.edit(user, socket.assigns.track_id, id, body), fn s, _ ->
       s |> assign(comment_editing: nil) |> load_comments()
     end)}
  end

  def handle_event("delete-comment", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    {:noreply,
     result(socket, Comments.delete(user, socket.assigns.track_id, id), fn s, _ ->
       s |> assign(comment_editing: nil) |> load_comments()
     end)}
  end

  def handle_event("retry-turn", %{"turn" => id}, socket) do
    with %{prompt: prompt} = turn when is_binary(prompt) <-
           Enum.find(socket.assigns.page.turns, &(&1.id == id)),
         true <- Enum.any?(turn.blocks, &match?(%TranscriptBlock.Failure{}, &1)) do
      {_speaker, body, _restored?} = visible_prompt(prompt)

      {:noreply,
       push_event(socket, "composer:retry", %{text: body, images: turn.image_count > 0})}
    else
      _ -> {:noreply, socket}
    end
  end

  # The composer's `@` in Ask mode. The first `@` reads the track's files;
  # later ones get what was read, and a copy older than `@file_index_ms` is
  # answered at once and read again behind it, since the agent is busy
  # making and removing files while the person types.
  def handle_event("mention-files", _, socket), do: {:noreply, file_index(socket)}

  def handle_event("starter", %{"prompt" => prompt}, socket),
    do: {:noreply, push_event(socket, "composer:insert", %{text: prompt})}

  # Stopping and waking are Fountain round trips, and they used to be ones
  # this process waited out, like the file read below. The button is
  # disabled until the answer lands; see `begin/3`.
  def handle_event("interrupt", _, socket) do
    thread_id = socket.assigns.thread_id
    {:noreply, begin(socket, :interrupt, &Tracks.interrupt(&1, &2, thread_id))}
  end

  # The model the shown conversation runs from its next turn. The menu is
  # disabled while a turn runs, which Fountain would refuse anyway.
  def handle_event("set-model", %{"model" => model}, socket) when is_binary(model) do
    thread_id = socket.assigns.thread_id
    model = if model == "", do: nil, else: model

    if MapSet.member?(socket.assigns.pending, :model),
      do: {:noreply, socket},
      else: {:noreply, begin(socket, :model, &Tracks.set_model(&1, &2, thread_id, model))}
  end

  # RAV-52: one of the shown conversation's session config options (effort
  # or Fast), from its next prompt. Checked here against the options this
  # page was shown, and again by the context against a fresh read: an id
  # that is not the effort or Fast option, or a value the runtime did not
  # list, never reaches it. Ids and values stay strings; no atom is made.
  # It shares the model's slot in `pending`: one write from the menu at a time.
  def handle_event("set-session-option", %{"id" => id, "choice" => value}, socket)
      when is_binary(id) and is_binary(value) do
    controls = SessionConfig.controls(socket.assigns.track.session_options)

    case SessionConfig.choose(controls, id, value) do
      {:ok, id, _value} -> {:noreply, set_session_option(socket, id, value)}
      :error -> {:noreply, session_option_refused(socket)}
    end
  end

  def handle_event("set-session-option", _params, socket),
    do: {:noreply, session_option_refused(socket)}

  def handle_event("retry-track", _, socket) do
    thread_id = socket.assigns.thread_id
    {:noreply, begin(socket, :retry, &Tracks.retry(&1, &2, thread_id))}
  end

  # The inspector's Wake. `Tracks.wake/2` holds the access check; the button
  # is only drawn for somebody it would let through.
  def handle_event("wake", _, socket) do
    if MapSet.member?(socket.assigns.pending, :wake),
      do: {:noreply, socket},
      else: {:noreply, begin(socket, :wake, &Tracks.wake/2)}
  end

  def handle_event("queue", %{"action" => "cancel", "id" => id}, socket),
    do: {:noreply, queued(socket, &PromptQueue.cancel/3, id)}

  def handle_event("queue", %{"action" => "retry", "id" => id}, socket),
    do: {:noreply, queued(socket, &PromptQueue.retry/3, id)}

  # RAV-94: Edit is Cancel, then the words back in the box to change and send
  # again. Only a waiting, text-only prompt this page is showing; the cancel
  # is `PromptQueue.cancel/3`, with its own check of who may, and nothing is
  # put in the box unless it succeeds. A draft in the box is not overwritten.
  def handle_event("queue", %{"action" => "edit", "id" => id}, socket) do
    item =
      Enum.find(
        socket.assigns.queue,
        &(&1.id == id and &1.status == :queued and &1.image_count == 0)
      )

    cond do
      is_nil(item) or not is_binary(item.prompt) ->
        {:noreply, socket}

      not socket.assigns.composer_empty? ->
        {:noreply,
         assign(socket, thread_error: "Send or clear your draft before editing a queued prompt.")}

      true ->
        {_speaker, body, _restored?} = visible_prompt(item.prompt)

        {:noreply,
         queued(socket, &PromptQueue.cancel/3, id, fn s ->
           s
           |> assign(composer_mode: :ask, thread_error: nil)
           |> push_event("composer:insert", %{text: body})
         end)}
    end
  end

  # Files and Changes come back from `Panel`'s cache at once and are read
  # again behind it; switching between them used to blank the tab for a
  # round trip to the machine every time. See `RavixWeb.Live.Panel`.
  def handle_event("panel", %{"name" => name}, socket) when is_map_key(@tabs, name) do
    panel = Panel.select(socket.assigns.panel, Map.fetch!(@tabs, name))
    socket = socket |> assign(panel: panel, narrow_view: "files") |> assign_turn()

    if Panel.cached?(panel),
      do: {:noreply, load_panel(socket, &Panel.reloading/1)},
      else: {:noreply, reload_panel(socket)}
  end

  def handle_event("select-diff", %{"path" => path}, socket) do
    {:noreply, assign(socket, diff_path: path, diff_show_large: false)}
  end

  def handle_event("close-diff", _, socket),
    do: {:noreply, assign(socket, diff_path: nil, diff_show_large: false)}

  def handle_event("filter-diff", %{"filter" => filter}, socket),
    do: {:noreply, assign(socket, diff_filter: filter)}

  def handle_event("show-large-diff", _, socket),
    do: {:noreply, assign(socket, diff_show_large: true)}

  def handle_event("refresh-panel", _, socket), do: {:noreply, reload_panel(socket)}

  def handle_event("toggle-ignored", _, socket),
    do: {:noreply, assign(socket, show_ignored?: !socket.assigns.show_ignored?)}

  def handle_event("directory", %{"path" => path}, socket) do
    socket = update_panel(socket, &%{&1 | metadata: Map.delete(&1.metadata, path)})

    if Map.has_key?(socket.assigns.panel.directories, path) do
      {:noreply, update_panel(socket, &%{&1 | directories: Map.delete(&1.directories, path)})}
    else
      user = socket.assigns.current_user
      id = socket.assigns.track_id
      token = make_ref()

      {:noreply,
       socket
       |> update_panel(&%{&1 | directories: Map.put(&1.directories, path, {:loading, token})})
       |> workspace_async({:directory, path, token}, fn -> Tracks.files(user, id, path) end)}
    end
  end

  # Reading a file is a Fountain round trip, and it used to be one this
  # process waited out: for as long as the machine took to answer, the page
  # drew nothing, answered no clicks and took no transcript events. Clicking
  # a file while an agent was talking stalled the conversation beside it.
  # The panel says it is busy and the answer arrives as `:file`.
  def handle_event("file", %{"path" => path}, socket) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id

    {:noreply,
     socket
     |> update_panel(&%{&1 | busy?: true, error: nil})
     |> workspace_async(:file, fn -> Tracks.file(user, id, path) end)}
  end

  # One clause per button, because the four are four different calls: two of
  # them need the session hash to mint a ticket with and two have no use for
  # it. A single clause taking the word the button sent could only hand that
  # word onward and let the context sort it out, which is how "stop" and a
  # typo became the same request.
  def handle_event("preview", %{"action" => "run"}, socket),
    do: {:noreply, preview_async(socket, "run", fn user, id, _hash -> Previews.run(user, id) end)}

  def handle_event("preview", %{"action" => "restart-run"}, socket),
    do:
      {:noreply,
       preview_async(socket, "restart-run", fn user, id, _hash ->
         Previews.run(user, id, :restart)
       end)}

  def handle_event("preview", %{"action" => "open"}, socket),
    do: {:noreply, preview_async(socket, "open", &Previews.open(&1, &2, &3))}

  def handle_event("preview", %{"action" => "restart"}, socket),
    do: {:noreply, preview_async(socket, "restart", &Previews.restart(&1, &2, &3))}

  def handle_event("preview", %{"action" => "stop"}, socket),
    do:
      {:noreply, preview_async(socket, "stop", fn user, id, _hash -> Previews.stop(user, id) end)}

  def handle_event("preview", %{"action" => "logs"}, socket),
    do:
      {:noreply, preview_async(socket, "logs", fn user, id, _hash -> Previews.logs(user, id) end)}

  def handle_event("preview-config", params, socket) do
    fields = Map.get(params, "preview_config", %{})
    config = if Params.flag(params, "clear"), do: nil, else: fields

    {:noreply,
     result(
       assign(socket, preview_form: Form.new(:preview_config, fields)),
       Previews.save_config(socket.assigns.current_user, socket.assigns.track_id, config),
       &show_preview(&1, &2),
       :preview_form
     )}
  end

  def handle_event("dialog", %{"name" => name}, socket) when is_map_key(@dialogs, name),
    do: {:noreply, open_dialog(socket, Map.fetch!(@dialogs, name))}

  def handle_event("dismiss", _, socket), do: {:noreply, assign(socket, dialog: nil)}

  def handle_event("rename", %{"rename_track" => %{"title" => title} = params}, socket) do
    {:noreply,
     result(
       assign(socket, rename_form: Form.new(:rename_track, params)),
       Tracks.rename(socket.assigns.current_user, socket.assigns.track_id, title),
       fn s, _ -> s |> assign(dialog: nil) |> refresh_detail() end,
       :rename_form
     )}
  end

  def handle_event("rebuild-machine", %{"force" => "true"}, socket) do
    {:noreply,
     result(
       socket,
       Tracks.rebuild_machine(socket.assigns.current_user, socket.assigns.track_id, force: true),
       fn s, _ -> s |> assign(dialog: nil) |> refresh_detail() end
     )}
  end

  def handle_event("rebuild-machine", _params, socket),
    do:
      {:noreply,
       put_flash(socket, :error, "Confirm deletion before rebuilding this track's machine.")}

  def handle_event("close", params, socket) do
    {:noreply,
     result(
       socket,
       Tracks.close(socket.assigns.current_user, socket.assigns.track_id,
         force: Params.flag(params, "force")
       ),
       fn s, _ ->
         if s.assigns.track.sandbox_layout == :dedicated,
           do: s |> assign(dialog: nil) |> refresh_detail(),
           else: redirect(s, to: "/p/#{s.assigns.project_id}")
       end
     )}
  end

  # A GitHub round trip, off this process for the same reason as the two
  # above. The dialog stays open until GitHub answers, so a refusal lands in
  # front of the form that caused it.
  def handle_event("open-pull", params, socket) do
    attrs = Map.put(params, "draft", Params.flag(params, "draft", true))
    {:noreply, begin(socket, :pull, &Tracks.open_pull(&1, &2, attrs))}
  end

  # The Checks tab's two Git writes. The message typed is kept on the page,
  # so a refused commit comes back to the words that were refused.
  def handle_event("commit-push", %{"message" => message}, socket) when is_binary(message) do
    {:noreply,
     socket
     |> assign(commit_message: message)
     |> git_write(:commit, &Tracks.commit_and_push(&1, &2, message))}
  end

  def handle_event("push", _, socket),
    do: {:noreply, git_write(socket, :push, &Tracks.push/2)}

  # Closing and rebuilding a dedicated track both delete its machine, so both
  # say what that machine still holds before anyone confirms.
  defp open_dialog(%{assigns: %{track: %{sandbox_layout: :dedicated}}} = socket, dialog)
       when dialog in [:close, :rebuild] do
    user = socket.assigns.current_user
    id = socket.assigns.track_id

    socket
    |> assign(dialog: dialog, close_info: nil)
    |> workspace_async(:close_info, fn -> Tracks.close_info(user, id) end)
  end

  # Rename opens on the name the track has now, so the dialog is a correction
  # rather than a blank box. The form is rebuilt each time it opens, which is
  # also what discards a refusal from the last attempt.
  defp open_dialog(socket, :rename),
    do:
      assign(socket,
        dialog: :rename,
        rename_form: Form.new(:rename_track, %{"title" => socket.assigns.track.title})
      )

  # Commit and push opens on the track's title, which is what the work is
  # for, unless an earlier attempt left a message of somebody's own.
  defp open_dialog(socket, :commit) do
    message =
      if String.trim(socket.assigns.commit_message) == "",
        do: socket.assigns.track.title,
        else: socket.assigns.commit_message

    assign(socket, dialog: :commit, commit_message: message)
  end

  defp open_dialog(socket, dialog), do: assign(socket, dialog: dialog)

  @impl true
  def handle_info({:agent_panel, id, tick}, socket) do
    if ThreadConnect.active?(
         socket.assigns.current_user,
         socket.assigns.project_id,
         socket.assigns.thread_connect,
         id
       ),
       do: send_update(RavixWeb.Live.AgentPanel, id: id, tick: tick)

    {:noreply, socket}
  end

  def handle_info({:agent_connected, user, agent}, socket) do
    connection = socket.assigns.thread_connect

    if connection && user.id == socket.assigns.current_user.id &&
         to_string(agent) == connection.runtime &&
         ThreadConnect.active?(
           user,
           socket.assigns.project_id,
           connection,
           connection.id
         ) do
      draft = socket.assigns.thread_draft
      draft = draft && %{draft | runtime: connection.runtime, model: nil}

      {:noreply,
       socket
       |> assign(current_user: user, thread_connect: nil, thread_draft: draft)
       |> draft_options()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:reconnect_agent, project_id}, socket) do
    if socket.parent_pid, do: send(socket.parent_pid, {:reconnect_agent, project_id})
    {:noreply, socket}
  end

  def handle_info({:reconnect_own_agent, runtime}, socket) do
    if socket.parent_pid, do: send(socket.parent_pid, {:reconnect_own_agent, runtime})
    {:noreply, socket}
  end

  def handle_info({:invalidate, _owner_id}, socket),
    do: handle_info(:refresh_agent_health, socket)

  def handle_info(:refresh_agent_health, socket),
    do: {:noreply, socket |> assign(agent_refused: false) |> update(:health_refresh, &(&1 + 1))}

  # The workspace's URL named a thread. The URL this page patched itself,
  # after a draft became a thread, names the one already shown.
  def handle_info({:select_thread, track_id, thread_id}, socket) do
    cond do
      track_id != socket.assigns.track_id ->
        {:noreply, socket}

      thread_id == socket.assigns.thread_id and not drafting?(socket) ->
        {:noreply, socket}

      match?({:ok, _}, Access.thread_access(socket.assigns.current_user, track_id, thread_id)) ->
        {:noreply, switch_thread(socket, thread_id)}

      true ->
        {:noreply, socket}
    end
  end

  # Ravix runs on more than one instance (ADR 0003) and a deploy is rolling,
  # so for one release a follower on an instance running the previous version
  # is still broadcasting Fountain's raw maps onto this topic. Normalising
  # here is the expand half of expand/contract: accept both shapes now, and
  # drop this clause once no instance publishes the old one.
  def handle_info({:transcript, id, %{} = raw}, socket) when not is_struct(raw),
    do: handle_info({:transcript, id, TranscriptEvent.from(raw)}, socket)

  def handle_info({:transcript, id, %TranscriptEvent{} = event}, socket) do
    socket = thread_activity(socket, id, event)

    if id == socket.assigns.thread_id and not drafting?(socket),
      do: {:noreply, socket |> absorb(event) |> schedule_flush() |> after_turn(event)},
      else: {:noreply, socket}
  end

  def handle_info(:flush_transcript, socket), do: {:noreply, flush(socket)}

  # An event about a *sibling* track is not this page's business, and saying
  # so is most of what typing the hub bought. A project with several tracks
  # being worked on publishes constantly -- a turn starting, a queue moving,
  # somebody reading a transcript -- and every one of those used to cost
  # every open page a re-read of its own track, its queue and its whole
  # transcript. An event naming no track at all is the project's, and is
  # never skipped.
  # The people dialog did the removal. Losing your own access to the track
  # you are looking at is the only one that moves you; taking somebody else
  # off it leaves you where you are.
  def handle_info({:person_removed, :track, login}, socket) do
    if login == socket.assigns.current_user.login,
      do: {:noreply, push_navigate(socket, to: "/")},
      else: {:noreply, socket}
  end

  # Somebody chose a different track in the rail.
  #
  # This page moves rather than being rebuilt, which is the whole reason
  # `RavixWeb.WorkspaceLive` gives it a fixed DOM id: a join, an access check,
  # `allow_upload/3` and three `attach_hook/4`s are all work whose answer is
  # about the person, not the track, and redoing them bought nothing but a
  # blank screen to do it in.
  #
  # `track` arrives from the rail, which read it for this person through
  # `Ravix.Tracks.list/2`, so the title, branch and status can be drawn in
  # this very patch instead of after a Fountain round trip. It is a head start
  # and never an authority: `authorized?/1` asks the database about *this*
  # person and *this* track before any of it renders, and the answer from
  # `Ravix.Tracks.get/3` replaces all of it a moment later.
  #
  # Everything the old track owned goes: its hub subscription if the project
  # changed too, its transcript follower, its panel, its queue, its dialog and
  # any images half-attached to a composer that is about to belong to
  # somewhere else.
  def handle_info({:select_track, project, track}, socket) do
    if track.id == socket.assigns.track_id do
      {:noreply, socket}
    else
      socket = arrive(socket, project, track)

      if authorized?(socket),
        do: {:noreply, socket |> assign(track_guard: renew(socket)) |> load()},
        else: {:noreply, redirect(socket, to: "/")}
    end
  end

  # What a terminal this page attached says; see `Ravix.Terminal.Shell`. The
  # guard hooks have already let it through.
  def handle_info({:terminal, tab_id, event}, socket),
    do: {:noreply, MachineDock.relay(socket, tab_id, event)}

  # A `live_component` cannot put a flash in the page's own socket, so it
  # sends the sentence here --- and this page has no toasts of its own
  # either, so `flash/3` sends it on up to the workspace, which draws the
  # one stack. See `RavixWeb.Live.Result.flash/3`.
  def handle_info({:flash, kind, message}, socket),
    do: {:noreply, flash(socket, kind, message)}

  # The dock's probe, sent from `RavixWeb.Live.MachineDock` in this same
  # process. One for a track this page has since left is dropped.
  def handle_info({:machine_probe, track_id, probe}, socket) do
    if track_id == socket.assigns.track_id do
      slept = socket.assigns.track && socket.assigns.track.sandbox_suspended_at

      {:noreply,
       socket
       |> assign(machine_probe: probe && {probe, slept})
       |> reread_refused(probe)
       |> assign_turn()}
    else
      {:noreply, socket}
    end
  end

  # The track's preview row changed, on whichever instance. The message says
  # nothing more than that: the guard attached at mount has already let it
  # through, and the re-read goes through `Previews.status/2`, which asks
  # this person's access again.
  def handle_info({:preview, track_id}, socket) do
    if track_id == socket.assigns.track_id,
      do: {:noreply, refresh_preview(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:hub, %Event{} = event}, socket) do
    if Event.concerns?(event, socket.assigns.track_id) do
      {:noreply, hub(event, socket)}
    else
      {:noreply, socket}
    end
  end

  # The countdown only moves while a retry is scheduled. Otherwise re-arm
  # slowly and assign nothing, so an idle track page does not re-render.
  def handle_info(:setup_clock, socket) do
    if match?(%{setup_state: "retry"}, socket.assigns.track) do
      Process.send_after(self(), :setup_clock, 1_000)
      {:noreply, socket |> assign(setup_now: DateTime.utc_now()) |> assign_turn()}
    else
      Process.send_after(self(), :setup_clock, 15_000)
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_plan_items, socket), do: {:noreply, refresh_plan_items(socket)}

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    {:noreply,
     socket
     |> update(:health_refresh, &(&1 + 1))
     |> refresh_detail()
     |> refresh_queue()
     |> refresh_plan_items()}
  end

  # The follower went away, which on a cluster means its instance did (ADR
  # 0003): `:global` releases the name and starts no replacement, and this page
  # is the only thing that still knows which event id it holds. So it starts a
  # fresh follower from that id and fetches only newer events to close whatever
  # the gap was. `follow/2` goes through `Tracks.follow/3`, so access is
  # re-established rather than assumed. A `:DOWN` for any other reference is a
  # monitor this page no longer owns.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    if socket.assigns.follower == ref do
      socket = assign(socket, follower: nil)

      {:noreply, socket |> follow(socket.assigns.page) |> catch_up_transcript()}
    else
      siblings = Map.reject(socket.assigns.sibling_followers, fn {_id, held} -> held == ref end)
      {:noreply, socket |> assign(sibling_followers: siblings) |> follow_siblings()}
    end
  end

  @impl true
  # Read afresh, and deliberately not left to the `:track_async_access` hook
  # attached at mount. The hook holds an answer for up to `Guard.ttl_ms/0`,
  # which is right for a message: the news that would have invalidated it
  # arrives on the hub, and the worst case is a page that is fifteen seconds
  # late to notice.
  #
  # An async result is not that. It carries data a provider was asked for
  # *before* the revocation --- a file listing, a diff, a transcript --- and
  # rendering it is handing somebody bytes they are no longer entitled to.
  # A track closed straight in the database publishes nothing for the hook to
  # hear, so the held answer would still stand. The two extra queries buy the
  # test named "track revocation rejects a delayed provider result", which is
  # worth them.
  def handle_async(name, {:ok, {:workspace, identity, response}}, socket) do
    current = Tracks.machine_identity(socket.assigns.current_user, socket.assigns.track_id)

    if current == identity and elem(current, 0) == :ok do
      handle_async(name, {:ok, response}, socket)
    else
      {:noreply,
       socket
       |> assign(preview_pending: nil)
       |> update_panel(fn panel ->
         Panel.new()
         |> Panel.select(panel.tab)
         |> Panel.failed("The workspace changed. Refresh to read its current files.")
       end)}
    end
  end

  def handle_async(name, response, socket) do
    if authorized?(socket) do
      {:noreply, name |> async_result(response, socket) |> assign_turn()}
    else
      {:noreply, redirect(socket, to: "/")}
    end
  end

  defp async_result({:plan_items, track_id}, {:ok, {:ok, summary}}, socket) do
    if track_id == socket.assigns.track_id do
      # A track invitation can survive removal of project membership while
      # this read is in flight. Recheck before exposing the plan's metadata.
      plan = visible_plan(socket.assigns.current_user, summary.plan)

      assign(socket, assigned_plan: %{summary | plan: plan})
    else
      socket
    end
  end

  defp async_result({:plan_items, _}, _response, socket), do: socket

  # The default the draft opens on, and every agent it may switch to. A
  # draft picked before the answer (the inline connect, say) keeps its pick.
  defp async_result(:thread_options, {:ok, {:ok, options}}, socket) do
    socket = settle(socket, :thread_options)

    case socket.assigns.thread_draft do
      nil ->
        socket

      draft ->
        draft = %{draft | options: options, source: options.source}
        assign(socket, thread_draft: pick(draft, draft.runtime, draft.model))
    end
  end

  defp async_result(:thread_options, {:ok, {:error, reason}}, socket),
    do: socket |> settle(:thread_options) |> assign(thread_error: Error.from(reason).message)

  defp async_result({:start_thread, draft_id}, {:ok, {:ok, thread}}, socket) do
    socket = settle(socket, :start_thread)
    draft = socket.assigns.thread_draft

    socket =
      if draft && draft.id == draft_id,
        do:
          socket
          |> assign(thread_draft: nil, thread_connect: nil, attached_images: [])
          |> push_event("composer:forget", %{key: draft_key(socket.assigns.track_id, draft)}),
        else: socket

    if thread.track_id == socket.assigns.track_id do
      if socket.parent_pid,
        do: send(socket.parent_pid, {:thread_started, thread.track_id, thread.id})

      socket |> assign(thread_error: nil) |> switch_thread(thread.id)
    else
      socket
    end
  end

  defp async_result({:start_thread, _draft_id}, {:ok, {:error, reason}}, socket),
    do: socket |> settle(:start_thread) |> assign(thread_error: thread_failure(socket, reason))

  defp async_result(:load, {:ok, {:ok, detail, project}}, socket) do
    Tracks.beat(socket.assigns.current_user, socket.assigns.track_id, :watching)

    Tracks.mark_read(
      socket.assigns.current_user,
      socket.assigns.track_id,
      socket.assigns.thread_id
    )

    socket
    |> assign(
      track: detail.track,
      setup_now: DateTime.utc_now(),
      threads: detail.threads,
      project: project,
      header: detail.header,
      starters: detail.starters,
      models: detail.models,
      loading: false
    )
    |> keep_shown_thread()
    |> assign_turn()
    |> billing_notice(detail.track)
    # This render is the one that puts `#transcript-turns` on the page, and a
    # stream's pending inserts are consumed by whichever render comes next
    # whether or not that render contains the container. So a transcript that
    # answered first --- it is a separate read now, and it does sometimes win
    # --- has already had its turns dropped into a page that had no transcript
    # in it yet, and they are gone. Whatever `page` holds by now is written
    # again here, into the container that finally exists. When the transcript
    # is the one still outstanding this is an empty reset, and its own result
    # inserts into a container that is by then real.
    |> follow_siblings()
    |> refresh_bound_machine(socket.assigns.track)
    |> memoize()
    |> stream(:turns, Transcript.visible_turns(socket.assigns.page), reset: true)
  end

  defp async_result(:load, {:ok, {:error, reason}}, socket),
    do: socket |> assign(loading: false) |> error(reason)

  defp async_result({:detail, thread_id, generation}, response, socket) do
    if thread_id == socket.assigns.thread_id and generation == socket.assigns.thread_generation,
      do: async_result(:detail, response, socket),
      else: socket
  end

  defp async_result(:detail, {:ok, {:ok, detail}}, socket),
    do:
      assign(socket,
        track: detail.track,
        setup_now: DateTime.utc_now(),
        header: detail.header,
        threads: detail.threads,
        models: detail.models
      )
      |> keep_shown_thread()
      |> assign_turn()
      |> follow_siblings()
      |> refresh_bound_machine(socket.assigns.track)

  defp async_result(:detail, {:ok, {:error, reason}}, socket), do: error(socket, reason)

  defp async_result(:close_info, {:ok, {:ok, info}}, socket),
    do: socket |> settle(:close_info) |> assign(close_info: info)

  defp async_result(:close_info, _response, socket),
    do: socket |> settle(:close_info) |> assign(close_info: :unavailable)

  defp async_result(:queue, {:ok, {:ok, queue}}, socket), do: assign(socket, queue: queue)

  defp async_result(:queue, {:ok, {:error, reason}}, socket), do: error(socket, reason)

  defp async_result({:earlier, thread_id, generation, cursor}, response, socket) do
    if thread_id == socket.assigns.thread_id and generation == socket.assigns.thread_generation do
      socket = assign(socket, earlier_loading: false)

      current_cursor = history_cursor(socket.assigns.page)

      case response do
        {:ok, {:ok, chunk}} when cursor == current_cursor ->
          history = Transcript.History.advance(socket.assigns.page.history, chunk.history)
          chunk = %{chunk | history: history}
          page = Transcript.prepend_history(socket.assigns.page, chunk)
          held = MapSet.new(socket.assigns.page.turns, & &1.id)
          earlier = Enum.reject(Transcript.visible_turns(page), &MapSet.member?(held, &1.id))
          socket = socket |> assign(page: page) |> memoize()
          Enum.reduce(Enum.reverse(earlier), socket, &stream_insert(&2, :turns, &1, at: 0))

        {:ok, {:ok, _stale}} ->
          socket

        {:ok, {:error, reason}} ->
          error(socket, reason)

        {:exit, _reason} ->
          flash(socket, :error, "Could not load earlier history. Please try again.")
      end
    else
      socket
    end
  end

  # The same clause serves the read this page opens with and every repair
  # afterwards, because the difference between them is one question --- is
  # this page already following the track's live transcript? --- and the
  # answer is in `follower` rather than in which call asked. A page that is
  # not following subscribes from what it just read, which covers the first
  # read, a follower that went down between the `:DOWN` clause's own attempt
  # and now, and a track that had no conversation when it opened and has one
  # by the time the backstop tick comes round.
  #
  # Subscribing from what it just read is only gapless when the follower is
  # started by this call. One that is already running keeps its own cursor
  # --- the prompt queue follows a new thread to deliver its first prompt, so
  # that one always is --- and whatever it sent between the read and the
  # subscription went to nobody here. When that is a turn's opening event,
  # the only one carrying its prompt, every later event still arrives and the
  # turn is drawn without what was asked (RAV-102). So a page that has just
  # subscribed reads once more from where this read stopped, as the `:DOWN`
  # clause does; its answer finds the page following and stops there. Any
  # later read under the same name replaces that one, so it is not the only
  # repair: every catch-up starts from `read_through` (see
  # `catch_up_transcript/1`).
  defp async_result(:transcript, {:ok, {:ok, page}}, socket) do
    subscribed? = is_nil(socket.assigns.follower)
    socket = if subscribed?, do: follow(socket, page), else: socket
    catch_up? = subscribed? and not is_nil(socket.assigns.follower)

    # Sorted, because these come out of the turns newest-first within each
    # turn and the page they are about to be laid into grows cheaply only
    # while each event is newer than the one before it.
    newer =
      socket.assigns.page.turns
      |> Enum.flat_map(& &1.events)
      |> Enum.filter(&(&1.id > (page.last_event_id || 0)))
      |> Enum.sort_by(& &1.id)

    read_through = page.last_event_id
    page = page |> Transcript.add_events(newer) |> retain_earlier(socket.assigns.page)

    socket
    |> assign(transcript_loading: false, read_through: read_through)
    |> advertise(
      page.turns
      |> Enum.flat_map(& &1.events)
      |> Enum.sort_by(& &1.id)
      |> Commands.latest()
    )
    |> repair(page)
    |> then(&if(catch_up?, do: catch_up_transcript(&1), else: &1))
  end

  defp async_result({:file_index, track_id}, response, socket) do
    if track_id == socket.assigns.track_id do
      socket = assign(socket, file_index_loading?: false)

      case response do
        {:ok, {:ok, %Files.Index{} = index}} ->
          socket
          |> assign(file_index: %{track_id: track_id, index: index, at: now_ms()})
          |> push_files(index)

        {:ok, {:error, :machine_asleep}} ->
          push_event(socket, "composer:files", %{
            paths: [],
            error: "This track's machine is asleep. Files can be mentioned when it wakes."
          })

        {:ok, {:error, reason}} ->
          push_event(socket, "composer:files", %{paths: [], error: Error.from(reason).message})

        {:exit, _reason} ->
          push_event(socket, "composer:files", %{paths: [], error: "Could not read the files."})
      end
    else
      socket
    end
  end

  defp async_result(:transcript, {:ok, {:error, reason}}, socket),
    do: socket |> assign(transcript_loading: false) |> error(reason)

  # Each tab's read is named after the tab, so reading one never cancels the
  # other and LiveView drops any answer older than the tab's latest read. An
  # answer for the tab on screen is shown; one for a tab somebody has since
  # left refreshes that tab's cache, and a refusal waits for the next visit,
  # which reads again.
  defp async_result({:panel, tab}, response, socket) do
    if tab == socket.assigns.panel.tab,
      do: async_result(:panel, response, socket),
      else: cache_result(tab, response, socket)
  end

  defp async_result(name, {:ok, {:error, :machine_asleep}}, socket)
       when name in [:panel, :file],
       do: asleep_panel(socket)

  defp async_result({:directory, path, token}, {:ok, {:error, :machine_asleep}}, socket) do
    if socket.assigns.panel.directories[path] == {:loading, token},
      do: asleep_panel(socket),
      else: socket
  end

  # The open file lands in the panel beside whatever the tab is listing, so
  # this clause settles the busy flag and leaves `data` where it is --- a
  # refusal here is about the file and must not empty the directory it was
  # picked from.
  defp async_result(:file, {:ok, response}, socket) do
    result(
      update_panel(socket, &Panel.settled/1),
      response,
      &update_panel(&1, fn panel -> Panel.open_file(panel, &2) end)
    )
  end

  defp async_result({:directory, path, token}, response, socket) do
    if socket.assigns.panel.directories[path] == {:loading, token} do
      value =
        case response do
          {:ok, {:ok, listing}} -> listing
          {:ok, {:error, reason}} -> {:error, Error.from(reason).message}
          {:exit, _} -> {:error, "Could not finish loading. Collapse and expand to retry."}
        end

      socket = update_panel(socket, &%{&1 | directories: Map.put(&1.directories, path, value)})
      if is_struct(value, Files.Listing), do: load_file_metadata(socket, value), else: socket
    else
      socket
    end
  end

  defp async_result({:file_metadata, path, token}, response, socket) do
    if socket.assigns.panel.metadata[path] == token do
      update_panel(socket, fn panel ->
        panel = %{panel | metadata: Map.delete(panel.metadata, path)}
        enrich_listing(panel, path, response)
      end)
    else
      socket
    end
  end

  defp async_result(:panel, {:ok, {:ok, %Files.Listing{} = listing}}, socket) do
    socket |> update_panel(&Panel.loaded(&1, listing)) |> load_file_metadata(listing)
  end

  defp async_result(:panel, {:ok, {:ok, %Previews.View{} = preview}}, socket),
    do: socket |> show_preview(preview) |> update_panel(&Panel.settled/1)

  defp async_result(:panel, {:ok, {:ok, {%Diff{} = diff, merged?}}}, socket) do
    socket
    |> assign(branch_merged?: merged?)
    |> update_panel(&Panel.loaded(&1, diff))
  end

  defp async_result(:panel, {:ok, {:ok, data}}, socket),
    do: update_panel(socket, &Panel.loaded(&1, data))

  defp async_result(:panel, {:ok, {:error, reason}}, socket),
    do: update_panel(socket, &Panel.failed(&1, Error.from(reason).message))

  defp async_result(:preview_action, {:ok, response}, socket) do
    socket
    |> assign(preview_pending: nil)
    |> result(response, fn s, preview -> s |> show_preview(preview) |> opened(preview) end)
  end

  defp async_result(:preview_action, {:exit, reason}, socket),
    do: socket |> assign(preview_pending: nil) |> exit(reason)

  # A re-read after `{:preview, track_id}`. One for a track this page has
  # since left is dropped, and so is a refusal: the guard and `handle_async/3`
  # have already answered a revoked reader, and anything else is left for the
  # next change or the panel's own refresh.
  defp async_result({:preview_status, id}, {:ok, {:ok, %Previews.View{} = preview}}, socket) do
    if id == socket.assigns.track_id,
      do: socket |> show_preview(preview) |> opened(preview),
      else: socket
  end

  defp async_result({:preview_status, _id}, _response, socket), do: socket

  # A stopped turn need not send another stage event, and the one that told
  # the tab it was running may be the last this page hears. So a stop that
  # Fountain accepted drops the shown thread's live state, as a `:turn` hub
  # event does, and the tab and Stop (RAV-87) fall back together to the
  # status the re-read brings. A refused stop leaves them as they were.
  defp async_result(:interrupt, {:ok, response}, socket),
    do:
      result(settle(socket, :interrupt), response, fn s, _ ->
        s
        |> drop_thread_state(s.assigns.thread_id)
        |> refresh_detail()
      end)

  defp async_result(:retry, {:ok, response}, socket),
    do: result(settle(socket, :retry), response, fn s, _ -> load(s) end)

  # Awake: read the tab again, from nothing, since what it held was the
  # asleep state rather than anything worth keeping on screen.
  defp async_result(:wake, {:ok, response}, socket),
    do:
      result(settle(socket, :wake), response, fn s, _ ->
        s |> refresh_detail() |> reload_panel()
      end)

  # The hub event `set_model/4` publishes refreshes every page on the track,
  # this one included; the refresh here is so this page does not wait on it.
  defp async_result(:model, {:ok, response}, socket),
    do: result(settle(socket, :model), response, fn s, _ -> refresh_detail(s) end)

  defp async_result(:pull, {:ok, response}, socket),
    do: result(settle(socket, :pull), response, &assign(&1, pull: &2, dialog: nil))

  # A read for the track this page has since left is not this track's status.
  defp async_result({:git_status, track_id}, _response, %{assigns: %{track_id: id}} = socket)
       when track_id != id,
       do: socket

  defp async_result({:git_status, _}, {:ok, {:ok, status}}, socket),
    do: assign(socket, git: %{status: status, error: nil, asleep?: false}, git_loading?: false)

  # Not an error: Git status says the machine is asleep, and offers to wake
  # it, the way Files and Changes do (`asleep/1`).
  defp async_result({:git_status, _}, {:ok, {:error, :machine_asleep}}, socket),
    do: assign(socket, git: %{status: nil, error: nil, asleep?: true}, git_loading?: false)

  defp async_result({:git_status, _}, {:ok, {:error, reason}}, socket),
    do:
      assign(socket,
        git: %{status: nil, error: Error.from(reason).message, asleep?: false},
        git_loading?: false
      )

  defp async_result({:git_status, _}, {:exit, reason}, socket),
    do:
      assign(socket,
        git: %{status: nil, error: Error.from({:async_exit, reason}).message, asleep?: false},
        git_loading?: false
      )

  defp async_result({:git_write, track_id}, _response, %{assigns: %{track_id: id}} = socket)
       when track_id != id,
       do: socket

  # Either way the worktree may have moved --- a push can fail after its
  # commit landed --- so the status is read again. A refusal stays on the
  # page, in the dialog if it is open, until the next attempt.
  defp async_result({:git_write, _}, {:ok, :ok}, socket) do
    notice = if socket.assigns.git_step == :commit, do: "Committed and pushed.", else: "Pushed."

    socket
    |> settle(:git)
    |> assign(git_failure: nil, commit_message: "", dialog: nil)
    |> flash(:info, notice)
    |> after_git_write()
  end

  defp async_result({:git_write, _}, {:ok, {:error, reason}}, socket),
    do:
      socket
      |> settle(:git)
      |> assign(git_failure: Error.from(reason).message)
      |> after_git_write()

  defp async_result({:git_write, _}, {:exit, reason}, socket),
    do:
      socket
      |> settle(:git)
      |> assign(git_failure: Error.from({:async_exit, reason}).message)
      |> after_git_write()

  # One of the ribbon's writes that did not answer. Not the loading clause
  # below: nothing was being loaded, and "could not finish loading" about a
  # Stop that crashed would be a sentence about the wrong thing.
  defp async_result({:start_thread, _draft_id}, {:exit, _reason}, socket),
    do:
      socket
      |> settle(:start_thread)
      |> assign(thread_error: thread_failure(socket, :unavailable))

  defp async_result(:thread_options, {:exit, _reason}, socket),
    do:
      socket
      |> settle(:thread_options)
      |> assign(thread_error: "Could not load the agents. Press + to try again.")

  defp async_result(name, {:exit, reason}, socket)
       when name in [:interrupt, :retry, :wake, :pull, :model],
       do: socket |> settle(name) |> exit(reason)

  # A background refresh that crashed leaves the page showing what it had.
  # The generic clause below belongs to the reads somebody is waiting on: it
  # clears `loading` and says so, which is the wrong answer for a tick nobody
  # asked for. Access lost mid-refresh is `Guard`'s to notice, not this.
  defp async_result(name, {:exit, _reason}, socket) when name in [:detail, :queue],
    do: socket

  defp async_result(_name, {:exit, _reason}, socket),
    do:
      socket
      |> assign(loading: false, transcript_loading: false)
      |> update_panel(&Panel.settled/1)
      |> flash(:error, "Could not finish loading. Please try again.")

  defp cache_result(tab, {:ok, {:ok, {%Diff{} = diff, merged?}}}, socket),
    do: socket |> assign(branch_merged?: merged?) |> update_panel(&Panel.cache(&1, tab, diff))

  defp cache_result(tab, {:ok, {:ok, %Files.Listing{} = listing}}, socket),
    do: update_panel(socket, &Panel.cache(&1, tab, listing))

  defp cache_result(_tab, _response, socket), do: socket

  defp history_cursor(page),
    do:
      {page.conversation_id, page.oldest_conversation_id, page.oldest_event_id,
       page.history && {page.history.conversation_id, page.history.before}}

  defp retain_earlier(
         %{history: %Transcript.History{} = incoming} = page,
         %{history: %Transcript.History{} = held} = current
       ) do
    if incoming.source == held.source and Transcript.History.further?(held, incoming),
      do: Transcript.prepend_history(page, current),
      else: page
  end

  defp retain_earlier(page, _current), do: page

  # The repair read, rendered as what actually differs.
  #
  # `Tracks.events/2` answers the whole transcript, and this used to hand all
  # of it to `stream/4` with `reset: true`: every turn's DOM replaced, on
  # every stage event of every turn, for a read whose usual answer is
  # "nothing you were not already told". The transcript is the longest thing
  # on the page and that is the message which arrives fastest, so the two
  # multiply.
  #
  # Only the shape a repair usually has is repaired turn by turn: the same
  # turns in the same order, some with more in them, possibly more after
  # them. Anything else --- a turn the provider no longer has, a gap filling
  # in the *middle*, a reorder --- resets, because `stream_insert/4` appends
  # and cannot express any of those. Getting that wrong would leave a ghost
  # turn or an out-of-order one on the screen, which is worse than the cost
  # this is avoiding.
  defp repair(socket, page) do
    was = Transcript.visible_turns(socket.assigns.page)
    now = Transcript.visible_turns(page)
    socket = socket |> assign(page: page) |> replay_thread_activity(page) |> memoize()

    if appended_to?(was, now),
      do: Enum.reduce(now, socket, &insert_changed(&2, was, &1)),
      else: stream(socket, :turns, now, reset: true)
  end

  defp replay_thread_activity(socket, page) do
    case List.last(page.turns) do
      %{settled?: true, events: events} ->
        if AgentFailure.suspension(events),
          do: put_thread_state(socket, socket.assigns.thread_id, :failed),
          else: socket

      _ ->
        socket
    end
  end

  # Are the turns on screen still the leading turns of the new page, in the
  # same order? Content may differ; identity and position may not.
  defp appended_to?(was, now) do
    length(now) >= length(was) and
      now |> Enum.take(length(was)) |> Enum.map(& &1.id) == Enum.map(was, & &1.id)
  end

  defp insert_changed(socket, was, turn) do
    case Enum.find(was, &(&1.id == turn.id)) do
      ^turn -> socket
      _other -> stream_insert(socket, :turns, turn)
    end
  end

  # Which assign the answer belongs in is a question about the answer. It used
  # to be asked of `socket.assigns.panel` instead, so a reply that arrived
  # after somebody switched tabs was filed under whichever panel they had
  # moved to.

  # The images a send carries: those retained from a refused send, and those
  # just uploaded. They stay in `attached_images` until a send succeeds.
  # File paths are issued by LiveView after validating its managed upload.
  # sobelow_skip ["Traversal.FileModule"]
  defp take_images(socket) do
    images =
      consume_uploaded_entries(socket, :images, fn %{path: path}, entry ->
        {:ok, %{data: Base.encode64(File.read!(path)), media_type: entry.client_type}}
      end)

    images = socket.assigns.attached_images ++ images
    {images, assign(socket, attached_images: images)}
  end

  # The draft's first message: the thread and the prompt are made together,
  # server-side, and nothing is shown as sent until both are. A second press
  # while the first is out does nothing here, and the draft's id is the
  # request id, so a second press that got past this still answers with the
  # thread the first one started. A refusal keeps the draft, its picks, the
  # typed text and the images, and says why beside the composer.
  defp start(socket, text) do
    draft = socket.assigns.thread_draft

    cond do
      MapSet.member?(socket.assigns.pending, :start_thread) ->
        socket

      is_nil(draft.options) ->
        assign(socket, thread_error: "Wait for the agents to load, then send.")

      true ->
        {images, socket} = take_images(socket)
        %{current_user: user, track_id: id} = socket.assigns

        attrs = %{
          "runtime" => draft.runtime,
          "model" => draft.model,
          "preference_explicit" => to_string(draft.explicit?)
        }

        payload = %{prompt: text, images: images, request_id: draft.id}

        socket
        |> assign(thread_error: nil)
        |> update(:pending, &MapSet.put(&1, :start_thread))
        |> traced_async({:start_thread, draft.id}, fn ->
          Tracks.start_thread(user, id, attrs, payload)
        end)
    end
  end

  defp drafting?(socket), do: match?(%{selected?: true}, socket.assigns.thread_draft)

  # Put the draft on screen. The shown thread's transcript stops following
  # (its tab keeps following, as a sibling's does), and choosing any thread
  # tab afterwards is a full switch back to it.
  defp show_draft(%{assigns: %{thread_draft: %{selected?: false}}} = socket) do
    socket
    |> unfollow()
    |> drop_pending()
    |> drop_attachments()
    |> update(:thread_generation, &(&1 + 1))
    |> update(:thread_draft, &%{&1 | selected?: true})
    # A draft has no thread to comment on yet; its first message is a prompt.
    |> assign(thread_error: nil, agent_refused: false, composer_mode: :ask, comment_editing: nil)
    |> follow_siblings()
  end

  defp show_draft(socket), do: socket

  defp draft_options(socket) do
    if MapSet.member?(socket.assigns.pending, :thread_options),
      do: socket,
      else: begin(socket, :thread_options, &Tracks.thread_options/2)
  end

  # Settle a pick against the agents on offer: an agent that is not one of
  # them is the default one, and a model the agent does not run is that
  # agent's first (the resolved default, for the default agent).
  defp pick(%{options: nil} = draft, runtime, model),
    do: %{draft | runtime: runtime, model: model}

  defp pick(%{options: options} = draft, runtime, model) do
    choice =
      Enum.find(options.runtimes, &(&1.runtime == runtime)) ||
        Enum.find(options.runtimes, &(&1.runtime == options.runtime)) ||
        %{runtime: options.runtime, models: []}

    %{draft | runtime: choice.runtime, model: pick_model(options, choice, model)}
  end

  defp pick_model(options, %{runtime: runtime, models: models}, model) do
    cond do
      is_binary(model) and model in models -> model
      runtime == options.runtime and (options.model in models or models == []) -> options.model
      true -> List.first(models)
    end
  end

  # The composer keeps unsent text in the browser under this key, so leaving
  # the draft and coming back finds it; each draft is new, so a reload, which
  # makes a new one, does not.
  defp draft_key(track_id, draft), do: "track:#{track_id}:thread:draft:#{draft.id}"

  defp send_prompt(socket, text) do
    {images, socket} = take_images(socket)

    response =
      Tracks.prompt(socket.assigns.current_user, socket.assigns.track_id, %{
        thread_id: socket.assigns.thread_id,
        prompt: text,
        images: images,
        request_id: Ecto.UUID.generate()
      })

    case response do
      {:error, reason} ->
        runtime = socket.assigns.track.runtime || socket.assigns.project.runtime
        error = RavixWeb.Error.from(reason)

        message =
          if error.code == "agent_not_connected",
            do: "#{payer_name(socket)} hasn't connected #{RavixWeb.AgentName.label(runtime)}.",
            else: error.message

        {:noreply, assign(socket, thread_error: message)}

      _ ->
        {:noreply,
         result(socket, response, fn s, _ ->
           Tracks.mark_read(s.assigns.current_user, s.assigns.track_id, s.assigns.thread_id)

           s
           |> assign(attached_images: [], agent_refused: false, thread_error: nil)
           |> push_event("composer:clear", %{})
           |> refresh_queue()
         end)}
    end
  end

  defp comment_mode(socket) do
    mentionable =
      case Comments.mentionable(socket.assigns.current_user, socket.assigns.track_id) do
        {:ok, people} -> people
        _ -> []
      end

    assign(socket, composer_mode: :comment, mentionable: mentionable)
  end

  # A comment is placed after the last turn on screen, which is what the
  # person commenting was looking at. The composer returns to asking the
  # agent, so the next Enter is not a comment by accident.
  # Until the transcript has loaded there is no turn to place a comment
  # after, and one posted then would sit above every turn in the thread.
  defp post_comment(%{assigns: %{transcript_loading: true}} = socket, _text),
    do:
      {:noreply,
       assign(socket, thread_error: "Wait for the conversation to load before commenting.")}

  defp post_comment(socket, text) do
    %{current_user: user, track_id: track_id, thread_id: thread_id, page: page} = socket.assigns

    anchor = %{
      anchor_turn_id: page |> Transcript.visible_turns() |> List.last() |> then(&(&1 && &1.id)),
      anchor_event_id: page.last_event_id
    }

    case Comments.post(user, track_id, thread_id, text, anchor) do
      {:ok, _comment} ->
        {:noreply,
         socket
         |> assign(composer_mode: :ask, thread_error: nil)
         |> push_event("composer:clear", %{})
         |> load_comments()}

      {:error, reason} ->
        {:noreply, assign(socket, thread_error: RavixWeb.Error.from(reason).message)}
    end
  end

  # The shown thread's comments, read again. Comments live inside the turn
  # they follow, and a stream item is only drawn when it is inserted, so the
  # turns whose comments changed are inserted again; everything else stays.
  defp load_comments(%{assigns: %{track_id: nil}} = socket), do: socket

  defp load_comments(socket) do
    %{current_user: user, track_id: track_id, thread_id: thread_id} = socket.assigns

    comments =
      case Comments.list(user, track_id, thread_id) do
        {:ok, comments} -> comments
        {:error, _} -> []
      end

    was = socket.assigns.comments
    changed = (comments -- was) ++ (was -- comments)

    socket
    |> assign(comments: comments)
    |> redraw_comments(Enum.map(changed, & &1.id), changed)
  end

  defp redraw_comments(socket, ids, known \\ []) do
    anchors =
      (known ++ socket.assigns.comments)
      |> Enum.filter(&(&1.id in ids))
      |> MapSet.new(& &1.anchor_turn_id)

    socket.assigns.page
    |> Transcript.visible_turns()
    |> Enum.filter(&MapSet.member?(anchors, &1.id))
    |> Enum.reduce(socket, &stream_insert(&2, :turns, &1))
  end

  # Comments after a turn, and the ones before the first: posted on an empty
  # thread, or after a turn the transcript no longer has. Those wait until
  # there is no earlier history left to load, so that a comment never sits
  # above turns that were posted before it.
  defp comments_after(comments, turn_id),
    do: Enum.filter(comments, &(&1.anchor_turn_id == turn_id))

  defp leading_comments(%{page: page, comments: comments, transcript_loading: loading}) do
    if loading or Transcript.History.more?(page.history) do
      []
    else
      shown = MapSet.new(Transcript.visible_turns(page), & &1.id)
      Enum.reject(comments, &(&1.anchor_turn_id && MapSet.member?(shown, &1.anchor_turn_id)))
    end
  end

  # Tell the page hosting this one where it is, so that choosing another track
  # can move it instead of replacing it. The session it mounted with is a
  # starting point and is never read again; every switch after that arrives as
  # `{:select_track, project, track}`. A page that is nobody's child --- there
  # is no route that renders this LiveView on its own today --- says nothing.
  defp announce(%{parent_pid: pid}) when is_pid(pid), do: send(pid, {:track_host, self()})
  defp announce(_socket), do: :ok

  # Hand this page over to another track, keeping only what belongs to the
  # person looking at it: the session, the guard's hash and expiry, the upload
  # config, the hooks, and the backstop tick. A hub subscription belongs to a
  # project rather than a track, so it is only exchanged when the project is.
  defp switch_thread(socket, id) do
    socket
    |> unfollow_siblings()
    |> unfollow()
    |> drop_attachments()
    |> update(:thread_generation, &(&1 + 1))
    |> assign(thread_id: id, agent_refused: false)
    |> assign_turn()
    |> update(:thread_draft, &(&1 && %{&1 | selected?: false}))
    |> load()
  end

  defp arrive(socket, project, track) do
    if project.id != socket.assigns.project_id do
      Hub.unsubscribe(socket.assigns.project_id)
      Hub.subscribe(project.id)
    end

    if track.id != socket.assigns.track_id do
      Previews.unsubscribe(socket.assigns.track_id)
      Previews.subscribe(socket.assigns.current_user, track.id)
    end

    socket
    |> unfollow_siblings()
    |> unfollow()
    |> drop_pending()
    |> drop_attachments()
    |> assign(
      track_id: track.id,
      thread_id: track.id,
      thread_generation: socket.assigns.thread_generation + 1,
      threads: [],
      thread_states: %{},
      thread_renaming: nil,
      file_index: nil,
      file_index_loading?: false,
      project_id: project.id,
      track: track,
      setup_now: DateTime.utc_now(),
      machine_probe: nil,
      project: project,
      header: nil,
      assigned_plan: %{items: [], plan: nil},
      starters: [],
      queue: [],
      thread_draft: nil,
      thread_connect: nil,
      thread_error: nil,
      billing_notice: nil,
      present: [],
      narrow_view: "conversation",
      panel: Panel.new(),
      show_ignored?: false,
      branch_merged?: false,
      diff_path: nil,
      diff_filter: "",
      diff_show_large: false,
      preview: nil,
      preview_form: Form.new(:preview_config),
      preview_url: nil,
      preview_pending: nil,
      preview_opening?: false,
      dialog: nil,
      rename_form: Form.new(:rename_track),
      pull: nil,
      git: nil,
      git_loading?: false,
      git_step: nil,
      git_failure: nil,
      commit_message: "",
      # A commit or push still running belongs to the track it was for; its
      # answer is dropped when it arrives here. See `async_result/3`.
      pending: MapSet.delete(socket.assigns.pending, :git)
    )
    |> assign_turn()
  end

  # An image chosen for one track's composer is not an image for the next
  # one's. The entries are LiveView's to cancel; `attached_images` is the
  # list this page already took delivery of.
  defp drop_attachments(socket) do
    socket.assigns.uploads.images.entries
    |> Enum.reduce(socket, &cancel_upload(&2, :images, &1.ref))
    |> assign(attached_images: [])
  end

  # Everything a track page opens with, started at once and rendered as each
  # piece lands.
  #
  # These used to be one `with` chain in one task, which made the page's first
  # paint cost the sum of four Fountain round trips: two inside `Tracks.get/2`
  # and two more inside `Tracks.events/2`, which reads the turns and the event
  # log. Nothing rendered until the last of them answered, so switching tracks
  # blanked the screen for as long as the slowest read took -- and the slowest
  # read is the transcript, which is also the only part of the page somebody
  # can wait a moment for.
  #
  # Split, the chrome (title, branch, ribbon, composer, panel tabs) paints
  # after `Tracks.get/2` alone while the transcript is still arriving, and the
  # two halves overlap instead of queueing. The queue and the panel start here
  # too, for the same reason: neither needs anything `:load` answers.
  defp load(socket) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    thread_id = socket.assigns.thread_id
    project_id = socket.assigns.project_id

    socket
    |> assign(
      loading: true,
      thread_error: nil,
      agent_refused: false,
      transcript_loading: true,
      earlier_loading: false,
      page: Transcript.empty(""),
      read_through: nil,
      rendered: %{},
      comments: [],
      comment_editing: nil,
      composer_mode: :ask,
      agent_commands: []
    )
    |> load_comments()
    |> drop_pending()
    |> stream(:turns, [], reset: true)
    # A load starts the page's transcript over from nothing, so the
    # subscription it had --- taken from a cursor this page has just thrown
    # away --- goes with it, and the read below establishes the next one.
    |> unfollow()
    |> traced_async(:load, fn ->
      # `fresh: false` drops the last Fountain round trip standing between
      # this page and its first paint. What it costs is a status dot, a turn
      # count and an unread mark that may be up to `MachineCache.ttl_ms/0`
      # old for the moment before the hub says otherwise --- and a track that
      # started running in the last five seconds is about to publish a `:turn`
      # to this very page's subscription, which is what corrects it. The
      # refresh below asks for fresh, because that one is running on the news.
      with {:ok, detail} <- Tracks.get(user, id, fresh: false, thread_id: thread_id),
           {:ok, project} <- Ravix.Projects.get(user, project_id),
           do: {:ok, detail, project}
    end)
    |> traced_async(:transcript, fn -> Tracks.events(user, id, thread_id: thread_id) end)
    |> refresh_queue()
    |> refresh_plan_items()
    |> load_panel()
    |> header_preview()
  end

  # The header's Preview control (RAV-42) draws from the same `preview`
  # assign as the panel, read once when the track arrives and then kept by
  # RAV-40's `{:preview, track_id}`. A thread switch keeps the one it has,
  # and the Preview tab's own read already covers it.
  defp header_preview(%{assigns: %{previews?: true, preview: nil}} = socket),
    do: if(socket.assigns.panel.tab == :preview, do: socket, else: refresh_preview(socket))

  defp header_preview(socket), do: socket

  # Read the event now, draw it in a moment. See `@flush_ms`.
  #
  # Which turns moved is remembered rather than which events arrived, because
  # that is what the drawing needs and a burst of two hundred frames usually
  # names one turn. A stage event is remembered as a flag for the same reason:
  # a turn that starts, runs and ends inside one window is three reasons to
  # re-read the track and one re-read.
  defp absorb(socket, event) do
    page = Transcript.add_event(socket.assigns.page, event)

    dirty =
      if TranscriptEvent.suspension(event),
        do: Enum.reduce(page.turns, socket.assigns.dirty_turns, &MapSet.put(&2, &1.id)),
        else: MapSet.put(socket.assigns.dirty_turns, event.turn_id)

    socket
    |> assign(
      page: page,
      dirty_turns: dirty,
      stage_seen?: socket.assigns.stage_seen? or event.kind == :stage,
      announcement: announce_turn(event, socket.assigns.announcement)
    )
    |> advertise(Commands.from_event(event))
  end

  defp advertise(socket, nil), do: socket
  defp advertise(socket, commands), do: assign(socket, agent_commands: commands)

  defp file_index(socket) do
    %{track_id: track_id, file_index: cached, current_user: user} = socket.assigns

    {socket, fresh?} =
      case cached do
        %{track_id: ^track_id, index: index, at: at} ->
          {push_files(socket, index), now_ms() - at < @file_index_ms}

        _ ->
          {socket, false}
      end

    if fresh? or socket.assigns.file_index_loading? do
      socket
    else
      socket
      |> assign(file_index_loading?: true)
      |> traced_async({:file_index, track_id}, fn -> Tracks.file_index(user, track_id) end)
    end
  end

  defp push_files(socket, %Files.Index{paths: paths, truncated: truncated}),
    do: push_event(socket, "composer:files", %{paths: paths, truncated: truncated})

  defp now_ms, do: System.monotonic_time(:millisecond)

  # The sentence for the live region, if this event is worth one. A turn
  # ending is; a turn starting clears the last one, so that two replies in a
  # row are two changes to the region and not one sentence left standing,
  # which a screen reader would read once. Everything else --- every token
  # of output --- leaves it alone.
  defp announce_turn(%TranscriptEvent{} = event, current) do
    cond do
      TranscriptEvent.starts_turn?(event) ->
        nil

      not TranscriptEvent.settles?(event) ->
        current

      TranscriptEvent.failed_stage?(event) or not is_nil(TranscriptEvent.suspension(event)) ->
        "Turn failed"

      true ->
        "Agent replied"
    end
  end

  # Shown to the creator once, the first time the track is visible to anybody
  # else; the server records it as shown in the same step.
  defp billing_notice(%{assigns: %{billing_notice: notice}} = socket, _track)
       when is_binary(notice),
       do: socket

  defp billing_notice(socket, %{billing: :creator, payer?: true} = track) do
    case Tracks.billing_notice(socket.assigns.current_user, track.id) do
      {:ok, notice} when is_binary(notice) -> assign(socket, billing_notice: notice)
      _ -> socket
    end
  end

  defp billing_notice(socket, _track), do: socket

  # "Paid by …" (ADR 0009 phase 6), said once, in the header's ⋯ popover
  # (RAV-82). Until then the header and the composer both said it, and the
  # header also said "Runs on @owner's agent", the same fact in other words.
  # The creator of a creator-billed track sees themselves, everybody else
  # sees who; an owner-billed track names its project's owner, and its owner
  # is not told they pay for their own project.
  defp payer_shown?(track, project), do: track.billing == :creator or project.role != :owner

  defp payer_label(%{payer?: true}), do: "Paid by you"

  defp payer_label(%{payer_login: login}) when is_binary(login) and login != "",
    do: "Paid by @#{login}"

  defp payer_label(%{owner_login: login}), do: "Paid by @#{login}"

  defp machine_scope(%{sandbox_layout: :dedicated}), do: "Own machine"
  defp machine_scope(_track), do: "Shared machine"

  defp machine_scope_title(%{sandbox_layout: :dedicated}), do: "This track's own machine"
  defp machine_scope_title(_track), do: "Used by all of this project's tracks"

  # Whether a header crumb is short enough to show whole. A longer one may
  # shrink, but only to its floor in app.css; a shorter one never shrinks,
  # which a floor alone would get wrong by padding it out to the floor.
  defp fits?(text, chars), do: String.length(text) <= chars

  # Whoever pays for this track's agent, as refusals name them: the creator
  # of a creator-billed track, else the project's owner, as before.
  defp payer_name(%{assigns: %{track: %{billing: :creator, payer_login: login}}}),
    do: "@#{login}"

  defp payer_name(socket), do: socket.assigns.project.owner_login

  defp schedule_flush(%{assigns: %{flushing?: true}} = socket), do: socket

  defp schedule_flush(socket) do
    Process.send_after(self(), :flush_transcript, @flush_ms)
    assign(socket, flushing?: true)
  end

  # Draw the turns that moved, and act once on whatever the stage events in
  # the window meant. A turn is looked up in `page` rather than remembered
  # from the event, so what is drawn is the turn as it stands at the end of
  # the window and not as it was when it was first touched.
  #
  # An empty window is not impossible: `load/2` and `arrive/3` clear what is
  # pending, and the timer they cannot cancel still arrives.
  defp flush(socket) do
    %{page: page, dirty_turns: dirty, stage_seen?: stage?} = socket.assigns

    socket =
      page.turns
      |> Enum.filter(&(&1.visible? and MapSet.member?(dirty, &1.id)))
      |> Enum.reduce(memoize(socket), &stream_insert(&2, :turns, &1))
      |> assign(dirty_turns: MapSet.new(), stage_seen?: false, flushing?: false)

    if stage? do
      Tracks.mark_read(
        socket.assigns.current_user,
        socket.assigns.track_id,
        socket.assigns.thread_id
      )

      socket |> refresh_detail() |> refresh_queue()
    else
      socket
    end
  end

  # Forget transcript events that were waiting to be drawn. The page they were
  # drawn into is being replaced, so drawing them would put one track's output
  # into another's, and a stage event from the track being left is not a
  # reason to re-read the one being arrived at.
  defp drop_pending(socket),
    do: assign(socket, dirty_turns: MapSet.new(), stage_seen?: false, announcement: nil)

  # Subscribe to the track's live transcript from the newest event this page
  # already has, and monitor the follower that serves it. The monitor is the
  # whole point: see the `:DOWN` clause above. The page's own transcript is
  # unaffected by a failure here, which is why an error is not surfaced -- the
  # events simply stop arriving and the fifteen-second refresh keeps working.
  defp follow(socket, page) do
    socket = unfollow(socket)

    case Tracks.follow(socket.assigns.current_user, socket.assigns.track_id,
           thread_id: socket.assigns.thread_id,
           after: page.last_event_id
         ) do
      {:ok, pid} -> assign(socket, follower: Process.monitor(pid))
      {:error, _reason} -> assign(socket, follower: nil)
    end
  end

  # Stop monitoring the follower this page had, so that `follower` says what
  # it is documented to say: nil is a page that is not following, and the
  # transcript read is what makes it one again.
  defp unfollow(socket) do
    Follower.unsubscribe(socket.assigns.thread_id)

    case socket.assigns.follower do
      nil ->
        socket

      ref ->
        Process.demonitor(ref, [:flush])
        assign(socket, follower: nil)
    end
  end

  # Each subscription uses the scoped context and shares the existing Follower.
  # Sibling frames only update tab state; they never enter this thread's transcript.
  defp follow_siblings(socket) do
    shown = if drafting?(socket), do: nil, else: socket.assigns.thread_id
    wanted = for thread <- socket.assigns.threads, thread.id != shown, do: thread.id

    held =
      Map.reject(socket.assigns.sibling_followers, fn {id, ref} ->
        if id in wanted do
          false
        else
          Follower.unsubscribe(id)
          Process.demonitor(ref, [:flush])
          true
        end
      end)

    held =
      Enum.reduce(wanted, held, fn id, acc ->
        if Map.has_key?(acc, id) do
          acc
        else
          follow_sibling(socket, id, acc)
        end
      end)

    assign(socket, sibling_followers: held)
  end

  defp follow_sibling(socket, id, held) do
    case Tracks.follow(socket.assigns.current_user, socket.assigns.track_id, thread_id: id) do
      {:ok, pid} -> Map.put(held, id, Process.monitor(pid))
      {:error, _} -> held
    end
  end

  defp unfollow_siblings(socket) do
    for {id, ref} <- socket.assigns.sibling_followers do
      Follower.unsubscribe(id)
      Process.demonitor(ref, [:flush])
    end

    assign(socket, sibling_followers: %{})
  end

  defp thread_activity(socket, id, %TranscriptEvent{kind: :stage, stage: "turn"} = event) do
    if Enum.any?(socket.assigns.threads, &(&1.id == id)) do
      status =
        case event.state do
          "started" -> :running
          "queued" -> :queued
          "failed" -> :failed
          _ -> :idle
        end

      put_thread_state(socket, id, status)
    else
      socket
    end
  end

  defp thread_activity(socket, id, %TranscriptEvent{} = event) do
    if not is_nil(TranscriptEvent.suspension(event)) and
         Map.get(socket.assigns.thread_states, id) == :running,
       do: put_thread_state(socket, id, :failed),
       else: socket
  end

  # Allocation can finish after the mount's empty reads. A binding change must
  # repair those reads immediately; the minute-long backstop is not readiness.
  defp refresh_bound_machine(socket, previous) do
    track = socket.assigns.track

    if (track.sandbox_layout == :dedicated and previous) &&
         {track.conversation_id, track.sandbox_state} !=
           {previous.conversation_id, previous.sandbox_state} do
      socket = socket |> unfollow() |> refresh_transcript()
      if track.sandbox_state == :ready, do: reload_panel(socket), else: socket
    else
      socket
    end
  end

  # Read what is newer than the last read, not than the last event. The
  # page's own cursor moves with the stream, and the stream can skip an
  # event: the one sent between a read and the subscription after it
  # (`async_result(:transcript, …)`). The next event still arrives and moves
  # the cursor past it, so a catch-up from there never asks for it again ---
  # and the one most likely to be skipped is a turn's opening event, the only
  # one carrying its prompt (RAV-102). The events a catch-up reads again are
  # ones the page already holds, and `Transcript.add_events/2` keeps one of
  # each.
  defp catch_up_transcript(socket) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    thread_id = socket.assigns.thread_id
    page = %{socket.assigns.page | last_event_id: socket.assigns.read_through}

    traced_async(socket, :transcript, fn ->
      Tracks.events(user, id, thread_id: thread_id, page: page)
    end)
  end

  defp refresh_transcript(socket) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    thread_id = socket.assigns.thread_id
    traced_async(socket, :transcript, fn -> Tracks.events(user, id, thread_id: thread_id) end)
  end

  # One of the ribbon's three writes, started off this process and named in
  # `pending` until its answer or its exit settles it. `call` takes the
  # person and the track, which is the shape all three share.
  defp begin(socket, name, call) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id

    socket
    |> update(:pending, &MapSet.put(&1, name))
    |> traced_async(name, fn -> call.(user, id) end)
  end

  defp settle(socket, name), do: update(socket, :pending, &MapSet.delete(&1, name))

  # One Git write at a time: a second press while one is out is dropped
  # rather than queued behind it. The track rides in the name, so an answer
  # for a track this page has left is recognised and dropped.
  defp git_write(%{assigns: %{pending: pending}} = socket, step, call) do
    if MapSet.member?(pending, :git) do
      socket
    else
      user = socket.assigns.current_user
      id = socket.assigns.track_id

      socket
      |> update(:pending, &MapSet.put(&1, :git))
      |> assign(git_step: step, git_failure: nil)
      |> traced_async({:git_write, id}, fn -> call.(user, id) end)
    end
  end

  # On Checks the pull request may have moved too, and `load_panel/2` reads
  # both; anywhere else only the status is kept current.
  defp after_git_write(socket) do
    if socket.assigns.panel.tab == :checks,
      do: load_panel(socket, &Panel.reloading/1),
      else: load_git(socket)
  end

  defp load_git(socket) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id

    socket
    |> assign(git_loading?: true)
    |> traced_async({:git_status, id}, fn -> Tracks.git_status(user, id) end)
  end

  defp set_session_option(socket, id, value) do
    thread_id = socket.assigns.thread_id

    if MapSet.member?(socket.assigns.pending, :model),
      do: socket,
      else: begin(socket, :model, &Tracks.set_session_option(&1, &2, thread_id, id, value))
  end

  defp session_option_refused(socket),
    do: flash(socket, :error, "That setting isn't offered for this agent and model.")

  # The preview buttons all do the same thing to the page -- say at once
  # which one is out, disable the rest, and answer later -- and differ only
  # in which context call they make, so that call is what they pass in. Not
  # the panel's `busy?`: that reads as "Loading inspector…", which is not
  # what a click on Run is doing.
  defp preview_async(socket, action, call) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    hash = socket.assigns.session_hash

    socket
    |> assign(preview_pending: action)
    |> workspace_async(:preview_action, fn -> call.(user, id, hash) end)
  end

  # The preview is only drawn once it is ready, with a ticket minted for this
  # session. An answer that is ready now carries one; one that is still
  # starting leaves the page waiting, and the re-read that finds it ready
  # mints a fresh ticket, since the click's is good for only a minute.
  defp opened(socket, %Previews.View{open_url: url, state: :ready}) when is_binary(url),
    do: assign(socket, preview_url: url, preview_opening?: false)

  defp opened(socket, %Previews.View{open_url: url}) when is_binary(url),
    do: assign(socket, preview_opening?: true)

  defp opened(socket, %Previews.View{state: state}) when state in [:failed, :stopped],
    do: assign(socket, preview_opening?: false)

  defp opened(socket, _preview), do: socket

  defp refresh_preview(socket) do
    %{current_user: user, track_id: id, session_hash: hash} = socket.assigns
    opening? = socket.assigns.preview_opening?

    traced_async(socket, {:preview_status, id}, fn ->
      user |> Previews.status(id) |> with_ticket(opening?, user, id, hash)
    end)
  end

  defp with_ticket({:ok, %Previews.View{state: :ready, url: url} = preview}, true, user, id, hash)
       when is_binary(url) do
    with {:ok, open_url} <- Previews.open_ticket(user, id, hash),
         do: {:ok, %{preview | open_url: open_url}}
  end

  defp with_ticket(answer, _opening?, _user, _id, _hash), do: answer

  @doc "The model under the composer: `RavixWeb.Live.ModelMenu.menu/1`."
  defdelegate model_menu(assigns), to: ModelMenu, as: :menu

  # "<model> · <effort>", and the Fast option's name when it is on: what the
  # runtime advertised, so before it has, the label is the model alone.
  defp thread_failure(socket, reason) do
    draft = socket.assigns.thread_draft || %{runtime: nil, options: nil}
    runtime = draft.runtime || socket.assigns.track.runtime || socket.assigns.project.runtime
    agent = RavixWeb.AgentName.label(runtime)

    fallback =
      RavixWeb.AgentName.label(
        Map.get(draft.options || %{}, :home_runtime, socket.assigns.project.runtime)
      )

    error = RavixWeb.Error.from(reason)

    case error.code do
      "agent_not_connected" ->
        "#{payer_name(socket)} hasn't connected #{agent}."

      code when code in ["sandbox_at_capacity", "conversation_busy", "machine_busy"] ->
        "#{agent} is at capacity on this machine; try again in a moment."

      code when code in ["guest_runtime_disabled", "invalid_runtime", "invalid_model"] ->
        error.message

      _ ->
        "Couldn't start a #{agent} thread on this machine; try again or use #{fallback}."
    end
  end

  # The ordinary wait, for the running turn, is the label's "sends when the
  # agent is free" (RAV-94); only an unusual one gets a line of its own.
  defp queue_feedback(item, runtime) do
    cond do
      item.status == :queued && item.error_code in ["sandbox_at_capacity", "conversation_busy"] ->
        "#{RavixWeb.AgentName.label(runtime)} is at capacity on this machine; your prompt is queued."

      item.wait_reason == PromptQueue.busy_wait() ->
        nil

      true ->
        item.wait_reason
    end
  end

  defp agent_model(runtime, model), do: ModelMenu.agent_model(runtime, model)

  attr :threads, :list, required: true
  attr :thread_id, :string, required: true
  attr :states, :map, default: %{}, doc: "each thread's tab word, from `@turn` (RAV-91)"
  attr :adding, :boolean, default: false
  attr :enabled, :boolean, required: true
  attr :draft, :map, default: nil, doc: "this page's unsent thread, if it has one"
  attr :track_label, :string, default: nil, doc: "`Track.label/1`: the first thread's name"
  attr :can_write, :boolean, default: false, doc: "may rename and close threads"
  attr :renaming, :string, default: nil, doc: "the thread whose title is a field now"

  @doc """
  The track's threads as a row of tabs above the conversation, with "+" at the
  end when threads can be added. A track with one thread that cannot gain
  another has nothing to switch between, so the row is not drawn at all.

  A tab shows its thread's title and nothing else (RAV-82), cut at about
  180px. Its agent, model and state are in its tooltip and accessible name;
  a dot is drawn only while it is running or has failed. The selected tab is
  underlined in the accent. The track's first thread, which every track has
  and which is stored as "Default", is named after the track until somebody
  renames it.

  RAV-97, for whoever can prompt the track:

    * a hover-only × closes (archives) a thread, while more than one is
      open; one still running is confirmed first (`close-thread`);
    * ✎ on the selected tab, a double-click, or F2 lays a name field over
      the tab (`edit-thread-title`); Enter or leaving it saves, Escape
      cancels. See the `ThreadTabs` hook.

  × and ✎ sit inside the tab for the pointer and are hidden from assistive
  technology, since a tab may not hold another control. The keyboard has the
  same through Delete and F2 on a tab, and through the shown thread's ⋯,
  which sits after the tablist: a tablist holds tabs and nothing else. So do
  the draft's discard, the ‹ › that scroll tabs which overrun the row, and
  "+", a menu whose New thread opens the draft tab.

  Manual-activation tabs use roving focus, Enter/Space selection, and one
  associated transcript panel. Narrow screens use the native picker.
  """
  def thread_tabs(assigns) do
    drafting? = match?(%{selected?: true}, assigns.draft)
    shown = if drafting?, do: nil, else: assigns.thread_id
    threads = Enum.map(assigns.threads, &first_thread_named(&1, assigns.track_label))
    renaming = assigns.can_write && Enum.find(threads, &(&1.id == assigns.renaming))

    assigns =
      assign(assigns,
        threads: threads,
        shown: shown,
        renaming: renaming,
        closable: assigns.can_write and length(threads) > 1,
        draft_label: assigns.draft && draft_label(assigns.draft),
        working:
          Enum.filter(threads, fn thread ->
            thread.id != shown and tab_status(thread, assigns.states) == "Running"
          end)
      )

    ~H"""
    <nav
      :if={length(@threads) > 1 or @enabled}
      id="thread-switcher"
      class="thread-tabs"
      phx-hook="ThreadTabs"
      aria-label="Threads"
      data-can-rename={@can_write}
      data-can-close={@closable}
      data-renaming={@renaming && @renaming.id}
      phx-mounted={JS.ignore_attributes(["data-overflow"])}
    >
      <form id="thread-picker-form" class="thread-picker" phx-change="select-thread">
        <label for="thread-picker" class="sr-only">Thread</label>
        <select id="thread-picker" name="thread_id">
          <option :for={thread <- @threads} value={thread.id} selected={thread.id == @shown}>
            {thread_option_label(thread, @states, @shown)}
          </option>
          <option :if={@draft} value="draft" selected={@draft.selected?}>{@draft_label}</option>
        </select>
      </form>
      <button
        type="button"
        id="thread-scroll-back"
        class="ghost icon-button thread-scroll"
        aria-label="Scroll threads left"
        data-tip="Scroll threads left"
        data-scroll="-1"
      >
        <.icon name="chevron" size={12} class="flip-x" />
      </button>
      <div id="thread-tablist" class="thread-tablist" role="tablist" aria-label="Threads">
        <button
          :for={thread <- @threads}
          type="button"
          id={"thread-tab-#{thread.id}"}
          role="tab"
          aria-selected={to_string(thread.id == @shown)}
          aria-controls="transcript-scroll"
          tabindex={if thread.id == @shown, do: "0", else: "-1"}
          class="thread-tab"
          phx-click="select-thread"
          phx-value-thread_id={thread.id}
          data-thread-id={thread.id}
          style={if @renaming && @renaming.id == thread.id, do: "anchor-name: --thread-renaming"}
          title={thread.title <> " · " <> agent_model(Map.get(thread, :runtime), Map.get(thread, :model)) <> " · " <> tab_status(thread, @states)}
          aria-label={thread.title <> " · " <> agent_model(Map.get(thread, :runtime), Map.get(thread, :model)) <> " · " <> tab_status(thread, @states) <> if(thread.unread && thread.id != @shown, do: " (unread)", else: "")}
        >
          <.status_dot
            :if={tab_status(thread, @states) in ["Running", "Failed"]}
            status={String.downcase(tab_status(thread, @states))}
          />
          <span class="thread-tab-title">{thread.title}</span><span
            :if={thread.unread && thread.id != @shown}
            class="thread-unread"
          ><span class="sr-only">(unread)</span></span><span
            :if={@can_write and thread.id == @shown}
            class="thread-tab-action thread-tab-rename"
            aria-hidden="true"
            data-tip="Rename thread"
            data-tip-kbd="F2"
            phx-click="edit-thread-title"
            phx-value-thread_id={thread.id}
          ><.icon name="pencil" size={11} /></span><span
            :if={@closable}
            class="thread-tab-action thread-tab-close"
            aria-hidden="true"
            data-tip="Close thread"
            data-tip-kbd="Del"
            phx-click="close-thread"
            phx-value-thread_id={thread.id}
          ><.icon name="x" size={11} /></span>
        </button>
        <button
          :if={@draft}
          type="button"
          id="thread-tab-draft"
          role="tab"
          aria-selected={to_string(@draft.selected?)}
          aria-controls="transcript-scroll"
          tabindex={if @draft.selected?, do: "0", else: "-1"}
          class="thread-tab thread-tab-draft"
          phx-click="select-thread"
          phx-value-thread_id="draft"
          data-thread-id="draft"
          title={@draft_label}
          aria-label={@draft_label <> " · Not started"}
        >
          <span class="thread-tab-title">New thread</span>
        </button>
      </div>
      <button
        type="button"
        id="thread-scroll-forward"
        class="ghost icon-button thread-scroll"
        aria-label="Scroll threads right"
        data-tip="Scroll threads right"
        data-scroll="1"
      >
        <.icon name="chevron" size={12} />
      </button>
      <form
        :if={@renaming}
        id="thread-rename-form"
        class="thread-rename"
        phx-submit="rename-thread"
        data-thread-id={@renaming.id}
      >
        <input type="hidden" name="thread_id" value={@renaming.id} />
        <input
          id="thread-rename-input"
          name="title"
          type="text"
          value={@renaming.title}
          maxlength="200"
          autocomplete="off"
          aria-label="Thread name"
        />
      </form>
      <button
        :if={@draft}
        type="button"
        id="thread-draft-discard"
        class="ghost icon-button thread-draft-discard"
        aria-label="Discard new thread"
        data-tip="Discard new thread"
        phx-click="discard-draft"
      >
        <.icon name="x" size={12} />
      </button>
      <div :if={@enabled} id="thread-add" class="chip-menu thread-add" phx-hook="ChipMenu">
        <button
          type="button"
          id="thread-add-trigger"
          class="ghost"
          popovertarget="thread-add-menu"
          aria-haspopup="dialog"
          aria-expanded="false"
          aria-controls="thread-add-menu"
          aria-label="Add thread"
          data-tip="Add thread"
          data-tip-kbd="Mod+T"
          disabled={@adding}
          phx-mounted={JS.ignore_attributes(["aria-expanded"])}
          style="anchor-name: --thread-add"
        >
          <.icon name="plus" size={14} />
        </button>
        <div
          id="thread-add-menu"
          class="chip-popover chip-popover-below chip-popover-end thread-menu"
          popover
          role="dialog"
          aria-label="Add"
          style="position-anchor: --thread-add"
        >
          <button type="button" class="account-item" data-chip-close phx-click="draft-thread">
            <span class="menu-check" aria-hidden="true"><.icon name="sparkle" size={14} /></span>New thread<kbd
              id="thread-new-shortcut"
              class="menu-kbd"
              phx-update="ignore"
              data-shortcut="t"
            >⌘T</kbd>
          </button>
        </div>
      </div>
      <div
        :if={(@can_write and @shown) && Enum.any?(@threads, &(&1.id == @shown))}
        id="thread-more"
        class="chip-menu thread-more"
        phx-hook="ChipMenu"
      >
        <button
          type="button"
          id="thread-more-trigger"
          class="ghost icon-button"
          popovertarget="thread-more-menu"
          aria-haspopup="dialog"
          aria-expanded="false"
          aria-controls="thread-more-menu"
          aria-label="More for this thread"
          data-tip="More for this thread"
          phx-mounted={JS.ignore_attributes(["aria-expanded"])}
          style="anchor-name: --thread-more"
        >
          <.icon name="more" size={14} />
        </button>
        <div
          id="thread-more-menu"
          class="chip-popover chip-popover-below chip-popover-end thread-menu"
          popover
          role="dialog"
          aria-label="More for this thread"
          style="position-anchor: --thread-more"
        >
          <button
            type="button"
            class="account-item"
            data-chip-close
            phx-click="edit-thread-title"
            phx-value-thread_id={@shown}
          >
            <span class="menu-check" aria-hidden="true"><.icon name="pencil" size={14} /></span>Rename thread<kbd class="menu-kbd">F2</kbd>
          </button>
          <button
            :if={@closable}
            type="button"
            class="account-item"
            data-chip-close
            phx-click="close-thread"
            phx-value-thread_id={@shown}
          >
            <span class="menu-check" aria-hidden="true"><.icon name="x" size={14} /></span>Close thread<kbd class="menu-kbd">Del</kbd>
          </button>
        </div>
      </div>
    </nav>
    <p :if={@working != []} id="threads-working" class="threads-working" role="status">
      {Enum.map_join(@working, "; ", fn thread ->
        "#{thread.title} (#{Ravix.AgentName.label(Map.get(thread, :runtime)) || "Agent"}) is working in this checkout"
      end)}.
    </p>
    """
  end

  defp closed_thread(socket, id) do
    threads = socket.assigns.threads
    index = Enum.find_index(threads, &(&1.id == id)) || 0
    left = Enum.reject(threads, &(&1.id == id))
    socket = assign(socket, threads: left, dialog: nil, thread_closing: nil, thread_renaming: nil)

    case {socket.assigns.thread_id == id, Enum.at(left, index) || List.last(left)} do
      {true, %{id: next}} -> switch_thread(socket, next)
      _ -> refresh_detail(socket)
    end
  end

  # A thread the page shows but the track no longer lists was closed --- by
  # somebody else, or before this page opened on it: show the first open one.
  defp keep_shown_thread(%{assigns: %{threads: [first | _] = threads}} = socket) do
    shown = socket.assigns.thread_id

    if match?(%{selected?: true}, socket.assigns.thread_draft) or
         Enum.any?(threads, &(&1.id == shown)),
       do: socket,
       else: switch_thread(socket, first.id)
  end

  defp keep_shown_thread(socket), do: socket

  # The name a thread's tab shows, for the dialog that closes it.
  defp thread_title(threads, id, track) do
    case Enum.find(threads, &(&1.id == id)) do
      nil -> "This thread"
      thread -> first_thread_named(thread, track && Track.label(track)).title
    end
  end

  # The tabs' titles, as the strip draws them.
  defp shown_threads(%{threads: threads, track: track}),
    do: Enum.map(threads, &first_thread_named(&1, track && Track.label(track)))

  defp first_thread_named(%{default: true, title: "Default"} = thread, label)
       when is_binary(label) and label != "",
       do: %{thread | title: label}

  defp first_thread_named(thread, _label), do: thread

  defp draft_label(%{runtime: nil}), do: "New thread"
  defp draft_label(draft), do: "New thread · " <> agent_model(draft.runtime, draft.model)

  defp thread_option_label(thread, states, current_id) do
    label =
      thread.title <> " · " <> agent_model(Map.get(thread, :runtime), Map.get(thread, :model))

    status = tab_status(thread, states)
    label = if status == "Idle", do: label, else: label <> " · " <> status
    label <> if(thread.unread && thread.id != current_id, do: " (unread)", else: "")
  end

  # RAV-91: `@turn`, the one reading of this track's turns and machine that
  # the thread tabs, the composer's Stop, the header's machine chip, the
  # dock and the inspector's asleep states all draw from, so none of them can
  # say Working, Idle or Asleep while another says something else. It is
  # recomputed after every async result (`handle_async/3`) and wherever
  # another of its inputs changes: the shown thread, the per-thread states
  # the stream brings (`put_thread_state/3`, `drop_thread_state/2`), the
  # panel (`update_panel/2`), the dock's probe and the setup clock.
  #
  # `states` is each thread's tab word. `running?` is the shown thread's
  # turn running, which is what Stop means; a thread missing from the list
  # (none read yet) has no tab to disagree with, and falls back to the
  # track's own status. `working?` is a turn running or queued on any of
  # them, which is what the machine is doing, and is read from the same
  # words rather than again from the track's status: a detail read's
  # `:running` left over from before the stream said the turn ended used to
  # hold the chip on Working under an Idle tab.
  #
  # `machine` is the chip's state (`machine/2`), which a read the machine
  # refused as asleep --- the inspector's or Checks' Git status --- now
  # makes Asleep too, rather than only the pane that asked saying so under
  # an Idle chip. A working turn outranks such a refusal: the machine is
  # awake for it, and the pane reads again (`after_turn/2`).
  defp assign_turn(socket), do: assign(socket, turn: turn(socket.assigns))

  defp turn(%{threads: threads, thread_states: states, thread_id: thread_id, track: track} = a) do
    labels = Map.new(threads, &{&1.id, thread_status(&1, states)})
    shown = Map.get_lazy(labels, thread_id, fn -> status_label(track && track.status) end)
    working? = Enum.any?([shown | Map.values(labels)], &(&1 in ["Running", "Queued"]))

    %{
      states: labels,
      running?: shown == "Running",
      working?: working?,
      machine: track && machine(a, working?)
    }
  end

  defp put_thread_state(socket, id, state),
    do: socket |> update(:thread_states, &Map.put(&1, id, state)) |> assign_turn()

  defp drop_thread_state(socket, id),
    do: socket |> update(:thread_states, &Map.delete(&1, id)) |> assign_turn()

  # Anything for send to send: text, as the `Composer` hook reports it, or
  # images, which are the server's to know and count only when asking.
  defp composer_filled?(empty?, mode, entries, attached),
    do: not empty? or (mode == :ask and (entries != [] or attached != []))

  # Who else is typing on this track, as the one line above the composer.
  defp typing_notice(present, viewer) do
    case for(p <- present, p.typing and p.login != viewer.login, do: "@" <> p.login) do
      [] ->
        nil

      [one] ->
        one <> " is typing…"

      names ->
        Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names) <> " are typing…"
    end
  end

  defp tab_status(thread, labels), do: Map.get(labels, thread.id, "Idle")

  defp thread_status(thread, states),
    do: status_label(Map.get(states, thread.id, Map.get(thread, :status)))

  defp status_label(:running), do: "Running"
  defp status_label(status) when status in [:pending, :queued], do: "Queued"
  defp status_label(:failed), do: "Failed"
  defp status_label(_status), do: "Idle"

  attr :count, :any, required: true, doc: "`Panel`'s `change_count`: `{files, truncated?}` or nil"

  # The Changes tab's count, once a diff read has said what it is. Nothing is
  # drawn for "not known yet" or for none: a 0 on a tab is a thing to read
  # that says nothing. The visible number is hidden from assistive tech and
  # said as words instead, so the button is "Changes, 3 changed files".
  defp change_badge(%{count: {files, truncated}} = assigns) when files > 0 do
    assigns = assign(assigns, files: files, more: if(truncated, do: "+", else: ""))

    ~H"""
    <span class="tab-count" aria-hidden="true">{@files}{@more}</span><span class="sr-only">, {changed_files(
      @files
    )}{if @more != "", do: " or more"}</span>
    """
  end

  defp change_badge(assigns), do: ~H""

  attr :show_ignored?, :boolean, default: false
  attr :branch_merged?, :boolean, default: false
  attr :directories, :map, default: %{}
  attr :metadata, :map, default: %{}
  attr :diff_path, :string, default: nil
  attr :diff_filter, :string, default: ""
  attr :diff_show_large, :boolean, default: false
  attr :data, :any, required: true
  attr :file, :any, default: nil
  attr :project, :any, required: true

  # Which panel is showing is a question about the value the panel is holding,
  # and these clauses ask it that way. The template used to ask a second
  # assign -- `@panel == "checks" && @panel_data` -- which made the pairing of
  # the two an invariant nothing enforced, and left the checks report being
  # read as `@panel_data[:runs] || []`: an `Access` read that answers `nil`
  # for a field that does not exist, so a renamed one would render an empty
  # list rather than fail.
  defp panel_body(%{data: %Files.Listing{}} = assigns) do
    ~H"""
    <div class="file-explorer">
      <div class="file-root" title={@data.path}>
        <.icon name="folder" />{Path.basename(@data.path)}
      </div>
      <p
        :if={!@data.ignore_available? && !Map.has_key?(@metadata, @data.path)}
        class="file-note"
      >
        Git ignore filtering is unavailable for this directory.
      </p>
      <.file_listing
        listing={@data}
        directories={@directories}
        file={@file}
        show_ignored?={@show_ignored?}
      />
      <div :if={@file}>
        <h4>{@file.path}</h4>
        <pre :if={@file.encoding != "base64"}>{@file.content}</pre>
        <p :if={@file.encoding == "base64"}>Binary file ({@file.size} bytes).</p>
        <p :if={@file.truncated}>File content is truncated.</p>
      </div>
    </div>
    """
  end

  # Fountain's diff answered but the sprite was asleep, so files Git is not
  # tracking yet could not be listed: "No changes" would be a guess.
  defp panel_body(%{data: %Diff{diff: "", untracked: :asleep}} = assigns) do
    ~H"""
    <.empty
      pane
      id="changes-empty"
      icon="moon"
      title="No tracked changes"
      because="The machine is asleep, so new files Git is not tracking yet cannot be listed."
    />
    """
  end

  defp panel_body(%{data: %Diff{diff: ""}} = assigns) do
    ~H"""
    <.empty
      pane
      id="changes-empty"
      icon="branch"
      title={if @branch_merged?, do: "Branch merged", else: "No changes yet"}
    />
    """
  end

  defp panel_body(%{data: %Diff{}} = assigns) do
    files = assigns.data.files
    selected = Enum.find(files, &(&1.change.path == assigns.diff_path))

    filtered =
      Enum.filter(
        files,
        &String.contains?(String.downcase(&1.change.path), String.downcase(assigns.diff_filter))
      )

    assigns =
      assign(assigns,
        selected: selected,
        filtered: filtered,
        added: Enum.sum(Enum.map(assigns.data.changes, & &1.added)),
        removed: Enum.sum(Enum.map(assigns.data.changes, & &1.removed))
      )

    ~H"""
    <div class="changes-panel">
      <p class="changes-summary">
        <span>{changed_files(length(@data.changes))}</span>
        <span class="change-counts">
          <span class="diff-add">+{@added}</span> <span class="diff-del">−{@removed}</span>
        </span>
      </p>
      <p :if={@data.truncated} class="changes-note">Diff is truncated.</p>
      <p :if={@data.untracked == :asleep} id="changes-untracked-asleep" class="changes-note">
        The machine is asleep, so new files Git is not tracking yet are not listed.
      </p>
      <div :if={!@selected}>
        <form id="diff-filter-form" phx-change="filter-diff" phx-submit="filter-diff">
          <label for="diff-filter" class="sr-only">Filter paths</label>
          <input
            id="diff-filter"
            name="filter"
            type="search"
            value={@diff_filter}
            placeholder="Filter paths"
            phx-debounce="150"
          />
        </form>
        <p :if={@filtered == []} class="changes-note">No matching files.</p>
        <button
          :for={file <- @filtered}
          type="button"
          class="change-file"
          phx-click="select-diff"
          phx-value-path={file.change.path}
        >
          <span
            class={"change-status change-#{file.change.status}"}
            title={diff_status_label(file.change.status)}
            aria-hidden="true"
          >{diff_status(file.change.status)}</span><span class="sr-only">{diff_status_label(
            file.change.status
          )}: </span>
          <span class="change-path"><span :if={file.change.status == :renamed}>{file.old_path} → </span><span class="change-directory">{diff_directory(
            file.change.path
          )}</span><strong>{Path.basename(file.change.path)}</strong></span>
          <span :if={file.partial} class="change-tag">Partial</span>
          <span :if={file.binary} class="change-tag">Binary</span>
          <span :if={!file.binary} class="change-counts"><span class="diff-add">+{file.change.added}</span>
          <span class="diff-del">−{file.change.removed}</span></span>
        </button>
      </div>
      <div :if={@selected}>
        <button type="button" phx-click="close-diff">← All changed files</button>
        <h4 class="change-path">
          <span :if={@selected.change.status == :renamed}>{@selected.old_path} → </span>{@selected.change.path}
        </h4>
        <p :if={@selected.partial}>
          {if @selected.hunks == [] and @selected.change.status == :untracked,
            do: "New file too large to show here.",
            else: "Partial file — diff was truncated."}
        </p>
        <p :for={line <- @selected.metadata}>{line}</p>
        <p :if={@selected.binary}>Binary files differ</p>
        <%= if large_diff?(@selected) and !@diff_show_large do %>
          <p>Large diff hidden to keep this panel responsive.</p>
          <button type="button" phx-click="show-large-diff">Show anyway</button>
        <% else %>
          <div
            :if={@selected.hunks != []}
            class="file-diff"
            tabindex="0"
            role="region"
            aria-label={"Diff for " <> @selected.change.path}
          >
            <div :for={hunk <- @selected.hunks} class="diff-hunk">
              <div class="diff-hunk-header">{hunk.header}</div>
              <div :for={line <- hunk.lines}>
                <div class={"diff-line diff-#{line.kind}"}>
                  <%!-- The gutter is visual; a screen reader hears one phrase instead. --%>
                  <span class="sr-only">{diff_line_label(line)}</span><span
                    class="diff-number"
                    aria-hidden="true"
                  >{line.old}</span><span class="diff-number" aria-hidden="true">{line.new}</span><span
                    class="diff-marker"
                    aria-hidden="true"
                  >{diff_marker(line.kind)}</span><code>{line.text}</code>
                </div>
                <div :if={line.no_newline} class="diff-no-newline">\ No newline at end of file</div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Siblings rather than one wrapper, so that with nothing run the empty
  # state is the panel's own child and fills it. Whether the branch was ever
  # pushed is the difference between "wait" and "push" (`ChecksReport`).
  defp panel_body(%{data: %ChecksReport{}} = assigns) do
    ~H"""
    <p :if={@data.pull}>
      <a href={@data.pull.url} target="_blank" rel="noreferrer">
        Pull request #{@data.pull.number}: {@data.pull.title}
      </a>
      <span class="chip pull-state">{pull_state_label(@data.pull.state)}</span>
    </p>
    <.empty
      :if={@data.runs == []}
      pane
      id="checks-empty"
      class="checks-empty"
      icon="check"
      title={if @data.pushed, do: "No checks yet", else: "No checks until the branch is pushed"}
    />
    <div :for={check <- @data.runs}>
      <a :if={check.url} href={check.url} target="_blank" rel="noreferrer">
        {check.name}
      </a>
      <span :if={!check.url}>{check.name}</span>
      <span class="chip">{check.conclusion || check.status}</span>
    </div>
    <a :if={@data.pull} href={@data.pull.url} target="_blank" rel="noreferrer">
      View on GitHub
    </a>
    """
  end

  attr :id, :string, required: true
  attr :can_wake, :boolean, required: true, doc: "Write access (ADR 0010)"
  attr :waking, :boolean, default: false

  # The machine is asleep, said once, with the Wake that `Tracks.wake/2`
  # answers. A Read member sees the state and no button: the context
  # refuses them anyway, and a button that is refused is a broken one.
  defp asleep(assigns) do
    ~H"""
    <.empty pane status id={@id} icon="moon" title="Machine is asleep">
      <:action
        :if={@can_wake}
        id="panel-wake"
        label={if @waking, do: "Waking…", else: "Wake"}
        click="wake"
        disabled={@waking}
      />
    </.empty>
    """
  end

  attr :git, :map,
    default: nil,
    doc: "`%{status:, error:, asleep?:}`, or nil before the first read"

  attr :can_wake, :boolean, default: false
  attr :waking, :boolean, default: false
  attr :loading, :boolean, default: false
  attr :checks, :any, default: nil, doc: "the loaded `ChecksReport`, if there is one"
  attr :checks_error, :string, default: nil
  attr :project, :any, required: true
  attr :writing, :atom, default: nil, doc: "`:commit` or `:push` while one is out"
  attr :failure, :string, default: nil

  attr :working, :boolean,
    default: false,
    doc: "`@turn.working?`: a turn is running or queued, so the counts are moving"

  attr :asleep, :boolean,
    default: false,
    doc: "this read was refused as asleep and `@turn.machine` agrees (no turn is working)"

  # What the worktree holds that GitHub does not, and the one action for
  # each: commit what is uncommitted, push what is unpushed, open a pull
  # request for what is pushed. The counts are the machine's own
  # (`Ravix.Tracks.git_status/2`); the pull request is the checks report's.
  defp git_status(assigns) do
    status = assigns.git && assigns.git.status
    assigns = assign(assigns, status: status)

    ~H"""
    <section id="git-status" class="git-status" aria-labelledby="git-status-title">
      <h3 id="git-status-title" class="git-status-title">
        Git status
        <span :if={@status && @status.branch} class="git-branch">
          <.icon name="branch" size={12} /><code>{@status.branch}</code>
        </span>
      </h3>
      <.loading_status :if={@loading && !@status} id="git-status-loading">
        Reading Git status…
      </.loading_status>
      <p :if={@git && @git.error} id="git-status-error" class="git-note" role="alert">
        {@git.error}
      </p>
      <%!-- RAV-91: the same turn the tab and the chip call Running and
        Working. These counts are re-read when it settles (`after_turn/2`);
        until then they are the worktree mid-turn, and a machine the turn is
        on is not asleep, whatever a read before it began said. --%>
      <p :if={@working} id="git-working" class="git-note" role="status">
        The agent is taking a turn. These counts are read again when it finishes.
      </p>
      <.asleep
        :if={@asleep}
        id="git-asleep"
        can_wake={@can_wake}
        waking={@waking}
      />
      <ul class="git-rows">
        <li :if={@status} id="git-uncommitted" class="git-row">
          <.git_count count={@status.uncommitted} />
          <span class="git-row-label">
            {count_label(@status.uncommitted, "uncommitted change", "uncommitted changes")}
          </span>
          <button
            :if={@status.uncommitted > 0}
            id="git-commit"
            type="button"
            class="primary"
            phx-click={JS.push_focus() |> JS.push("dialog")}
            phx-value-name="commit"
            disabled={@writing != nil}
          >
            Commit and push
          </button>
        </li>
        <li :if={@status} id="git-unpushed" class="git-row">
          <.git_count count={@status.unpushed} />
          <span class="git-row-label">
            {count_label(@status.unpushed, "unpushed commit", "unpushed commits")}<span
              :if={!@status.upstream? && @status.unpushed > 0}
              class="git-hint"
            > · branch not on GitHub yet</span>
          </span>
          <button
            :if={@status.unpushed > 0}
            id="git-push"
            type="button"
            phx-click="push"
            disabled={@writing != nil}
          >
            Push
          </button>
        </li>
        <li id="git-pull" class="git-row">
          <.icon name="pull" size={14} class="git-row-icon" />
          <span :if={@checks && @checks.pull} class="git-row-label">
            <a href={@checks.pull.url} target="_blank" rel="noreferrer">
              Pull request #{@checks.pull.number}
            </a>
            <span class="chip pull-state">{pull_state_label(@checks.pull.state)}</span>
          </span>
          <span :if={@checks && !@checks.pull} class="git-row-label">No pull request</span>
          <span :if={!@checks && @checks_error} class="git-row-label">Pull request unknown</span>
          <span :if={!@checks && !@checks_error} class="git-row-label">Checking pull request…</span>
          <button
            :if={@project.repo && @checks && !@checks.pull}
            id="git-create-pull"
            type="button"
            phx-click={JS.push_focus() |> JS.push("dialog")}
            phx-value-name="pull"
          >
            Create pull request
          </button>
        </li>
      </ul>
      <.loading_status :if={@writing} id="git-writing">
        {if @writing == :commit, do: "Committing and pushing…", else: "Pushing…"}
      </.loading_status>
      <p :if={@failure} id="git-failure" class="git-failure" role="alert"><span>{@failure}</span></p>
    </section>
    """
  end

  attr :count, :integer, required: true

  # A number to act on, in amber; none is a grey dash rather than a green 0,
  # which reads as a count of successes. The row's words say it either way.
  defp git_count(%{count: 0} = assigns) do
    ~H"""
    <span class="git-count zero" aria-hidden="true">–</span>
    """
  end

  defp git_count(assigns) do
    ~H"""
    <span class="chip warn git-count" aria-hidden="true">{@count}</span>
    """
  end

  # The toolbar's one icon says what it refreshes.
  defp refresh_label(:files), do: "Refresh files"
  defp refresh_label(:changes), do: "Refresh changes"
  defp refresh_label(:checks), do: "Refresh checks"
  defp refresh_label(:preview), do: "Refresh preview"

  # Nothing running and nothing failed: the Preview tab is its empty state.
  defp preview_idle?(preview), do: preview.state == :stopped and !preview.error

  defp count_label(0, _one, many), do: "No " <> many
  defp count_label(1, one, _many), do: "1 " <> one
  defp count_label(n, _one, many), do: "#{n} " <> many

  # Setup is waiting on a sleeping shared machine that it will not wake by
  # itself; a prompt or the wake button does. See `Ravix.Tracks.Setup`.
  defp parked?(track),
    do: track.setup_state == "running" and track.setup_error_code == "sandbox_suspended"

  # What the inspector shows in place of its tab when the machine behind the
  # tab cannot answer: the setup step while setup runs or the machine is
  # being made (the same words as the setup banner), or that it is asleep.
  # Asleep is the machine's own word --- a refused read or setup parked on
  # it --- never a guess from the clock. The Checks tab reads GitHub as well
  # as the machine, so there only its Git status says so (`git_status/1`).
  # A refusal is also `@turn`'s machine (RAV-91), so the chip says Asleep
  # whenever a tab does. One the chip has outranked --- a turn is working on
  # the machine --- is read again (`after_turn/2`), and says so meanwhile.
  defp inspector_state(track, machine, panel) do
    cond do
      machine.state in [:starting, :restarting] and
          (track.setup_state != "ready" or track.sandbox_state == :provisioning) ->
        {:setup, machine.detail}

      panel.data == :machine_asleep and machine.state == :working ->
        {:setup, "Reading the machine again…"}

      parked?(track) or panel.data == :machine_asleep ->
        :asleep

      true ->
        nil
    end
  end

  # What setup is doing, as the named steps it goes through, so the first
  # minute of a new track reads as progress rather than as one spinner. The
  # step under way is the machine's stage where it reports one (a dedicated
  # machine does) and otherwise follows `setup_state`. Each step is `:done`,
  # `:now`, `:failed` or `:todo`.
  @doc false
  def setup_steps(track, project) do
    current = setup_step_now(track.sandbox_stage, track.setup_state)
    failed = track.setup_state == "failed"

    track
    |> setup_step_labels(project && project.repo)
    |> Enum.with_index()
    |> Enum.map(fn {{key, label}, index} ->
      %{key: key, label: label, state: setup_step_state(index, current, failed)}
    end)
  end

  defp setup_step_labels(track, repo) do
    machine =
      if track.sandbox_layout == :dedicated,
        do: "Start this track's machine",
        else: "Wake the project machine"

    clone = if repo, do: "Check out #{repo} on a new branch", else: "Make a new branch"

    [
      {:machine, machine},
      {:clone, clone},
      {:setup, "Run setup"},
      {:agent, "Hand your first prompt to the agent"}
    ]
  end

  defp setup_step_now(_stage, "ready"), do: 3
  defp setup_step_now("creating", _state), do: 0
  defp setup_step_now("cloning", _state), do: 1
  defp setup_step_now("setup", _state), do: 2
  defp setup_step_now(_stage, "pending"), do: 1
  defp setup_step_now(_stage, _state), do: 2

  defp setup_step_state(index, current, _failed) when index < current, do: :done
  defp setup_step_state(current, current, true), do: :failed
  defp setup_step_state(current, current, false), do: :now
  defp setup_step_state(_index, _current, _failed), do: :todo

  defp pull_state_label(:merged), do: "Merged"
  defp pull_state_label(:closed), do: "Closed"
  defp pull_state_label(:open), do: "Open"

  defp setup_label(track, now), do: MachineState.setup_label(track, now)

  # One state for the track's machine, working while a turn is (RAV-91):
  # the per-thread states this page hears on the stream are fresher than the
  # last detail read, and the tabs read the same ones. Then what the dock's
  # probe knows, and what a refused read said. See `turn/1`.
  defp machine(%{track: track} = assigns, working?) do
    machine =
      track
      |> MachineState.of(running: working?, now: assigns.setup_now)
      |> probed(assigns.machine_probe, track)

    cond do
      # A preview start is waking the machine (`Ravix.Previews.open/3`): the
      # row still says asleep until the wake answers, and the header, the
      # dock and the panel say the same thing meanwhile.
      match?(%Previews.View{state: :waking}, assigns[:preview]) ->
        %{state: :starting, detail: "Waking this track's machine for the preview…"}

      # `:starting` is only said once the row reads awake again, so a header
      # still holding Asleep is a detail read that has not landed yet.
      machine.state == :asleep and match?(%Previews.View{state: :starting}, assigns[:preview]) ->
        %{state: :idle, detail: nil}

      machine.state in [:idle, :starting] and not working? and refused_asleep?(assigns) ->
        %{state: :asleep, detail: "Your next message wakes it."}

      true ->
        machine
    end
  end

  defp refused_asleep?(%{panel: panel, git: git}),
    do: panel.data == :machine_asleep or match?(%{asleep?: true}, git)

  # A probe that finds the machine running (a terminal woke it, say) is the
  # machine awake, so a pane or Git status it had refused as asleep is read
  # again (RAV-91): the refusal is `@turn`'s Asleep, and is not left to hold
  # the chip there once the machine answers.
  defp reread_refused(socket, %{available: true}) do
    socket
    |> then(&if(&1.assigns.panel.data == :machine_asleep, do: reload_panel(&1), else: &1))
    |> then(&if(match?(%{asleep?: true}, &1.assigns.git), do: load_git(&1), else: &1))
  end

  defp reread_refused(socket, _probe), do: socket

  # The header chip's state, corrected and qualified by what the dock's probe
  # knows that the track row does not: that the machine is in fact running
  # (the row's Asleep is cleared on the way --- unless the row has recorded
  # a sleep since the probe answered), or, for a machine the row can
  # only call Idle, that there is no machine yet, that this deployment cannot
  # reach machines at all, or that the machine did not answer. Every other
  # state already says what it is doing, and the probe does not add to it.
  defp probed(machine, nil, _track), do: machine

  defp probed(%{state: :asleep} = machine, {%{available: true}, slept}, %{
         sandbox_suspended_at: slept
       }),
       do: %{machine | state: :idle, detail: nil}

  defp probed(%{state: :idle} = machine, {probe, _slept}, _track) do
    case probe_note(probe) do
      nil -> machine
      note -> note(machine, note)
    end
  end

  defp probed(machine, _probe, _track), do: machine

  defp probe_note(%{why: :no_machine}), do: "No machine is available yet."

  defp probe_note(%{why: :no_token}),
    do: "Machine status is unavailable because the machine connection is not configured."

  defp probe_note(%{why: why}) when why in [:no_sprite, :unreachable],
    do: "The machine did not answer just now; your next message wakes it."

  defp probe_note(:unavailable), do: "Machine status is unavailable. Try again later."
  defp probe_note(_probe), do: nil

  defp note(%{detail: nil} = machine, note), do: %{machine | detail: note}
  defp note(%{detail: detail} = machine, note), do: %{machine | detail: detail <> " " <> note}

  attr :machine, :map, required: true

  # The header's state chip, and the page's one live region for the machine's
  # state. Only the word is announced: the detail can tick (a retry
  # countdown), so it describes the chip rather than announcing. Idle and
  # Working are the normal states, and the header does not draw them
  # (RAV-82): the chip is then visually hidden, not removed, so the live
  # region stays put and still announces the change. Its word is always
  # drawn whole; it never shrinks to its dot.
  defp machine_chip(assigns) do
    assigns = assign(assigns, normal?: assigns.machine.state in [:idle, :working])

    ~H"""
    <span
      id="track-machine-state"
      class={["chip machine-chip machine-#{@machine.state}", @normal? && "sr-only"]}
      role="status"
      aria-live="polite"
      aria-describedby={@machine.detail && "track-machine-detail"}
      data-tip={@machine.detail || MachineState.label(@machine.state)}
    ><.status_dot status={to_string(@machine.state)} /><span class="chip-label">{MachineState.label(
      @machine.state
    )}</span></span>
    <span :if={@machine.detail} id="track-machine-detail" class="sr-only">{@machine.detail}</span>
    """
  end

  attr :preview, Previews.View, required: true
  attr :can_start, :boolean, required: true

  # The header's way to the preview (RAV-42): what state it is in, and one
  # click to the Preview tab. It never starts anything itself --- a click
  # on "Start preview" opens the tab, where Run is --- so a stray click does
  # not wake a machine. A closed inspector is opened first (`PanelToggle`);
  # on a phone, `"panel"` switches the page to the inspector, as its Files
  # button does.
  defp preview_chip(assigns) do
    assigns = assign(assigns, look: preview_look(assigns.preview, assigns.can_start))

    ~H"""
    <button
      id="track-preview"
      type="button"
      class={["ghost track-preview", "preview-#{@look.kind}"]}
      phx-click={
        JS.dispatch("ravix:open-panel", to: "#inspector-toggle")
        |> JS.push("panel", value: %{name: "preview"})
      }
      aria-controls="inspector"
      data-tip={@look.tip}
    >
      <.status_dot :if={@look.dot} status={@look.dot} /><.icon
        :if={!@look.dot}
        name="globe"
        size={13}
      /><span class="chip-label" data-fit-label>{@look.label}</span>
    </button>
    """
  end

  defp preview_look(%Previews.View{state: state}, _can_start) when state in [:ready, :running],
    do: %{kind: "ready", dot: "ready", label: "Preview", tip: "Preview running: show it"}

  defp preview_look(%Previews.View{state: :waking}, _can_start),
    do: %{
      kind: "pending",
      dot: "starting",
      label: "Preview starting…",
      tip: "Waking this track's machine for the preview"
    }

  defp preview_look(%Previews.View{state: :starting}, _can_start),
    do: %{kind: "pending", dot: "starting", label: "Preview starting…", tip: "Preview starting"}

  defp preview_look(%Previews.View{state: state, error: error}, _can_start)
       when state == :failed or is_binary(error),
       do: %{
         kind: "failed",
         dot: "failed",
         label: "Preview failed",
         tip: "The preview didn't start: show why"
       }

  defp preview_look(_preview, true),
    do: %{
      kind: "stopped",
      dot: nil,
      label: "Start preview",
      tip: "Open the Preview tab to run one"
    }

  defp preview_look(_preview, false),
    do: %{kind: "stopped", dot: nil, label: "Preview", tip: "No preview running"}

  attr :present, :list, required: true

  # Who is looking at the track now, as Share's stacked avatars (RAV-82)
  # rather than a bare count. The count is said in words to assistive tech;
  # past three faces the rest are a "+n".
  defp viewers(assigns) do
    assigns =
      assign(assigns, shown: Enum.take(assigns.present, 3), more: length(assigns.present) - 3)

    ~H"""
    <span :if={@present != []} class="track-viewers">
      <span
        :for={viewer <- @shown}
        class="track-viewer"
        aria-hidden="true"
        title={"@" <> viewer.login}
      >
        <img :if={Map.get(viewer, :avatar_url)} src={viewer.avatar_url} alt="" loading="lazy" />
        <span :if={!Map.get(viewer, :avatar_url)}>{viewer.login |> String.first() |> String.upcase()}</span>
      </span>
      <span :if={@more > 0} class="track-viewer track-viewer-more" aria-hidden="true">+{@more}</span>
      <span class="sr-only">{length(@present)} viewing now</span>
    </span>
    """
  end

  defp diff_status(status),
    do: %{added: "A", modified: "M", deleted: "D", renamed: "R", untracked: "U"}[status]

  defp diff_status_label(status),
    do:
      %{
        added: "Added",
        modified: "Modified",
        deleted: "Deleted",
        renamed: "Renamed",
        untracked: "New, untracked"
      }[status]

  defp changed_files(1), do: "1 changed file"
  defp changed_files(count), do: "#{count} changed files"
  defp diff_marker(kind), do: %{add: "+", del: "−", context: " "}[kind]

  defp diff_line_label(%{kind: :add, new: new}), do: "Added line #{new}: "
  defp diff_line_label(%{kind: :del, old: old}), do: "Removed line #{old}: "
  defp diff_line_label(%{new: new}), do: "Line #{new}: "

  attr :show_ignored?, :boolean, required: true
  attr :ancestors, :list, default: []
  attr :listing, :any, required: true
  attr :directories, :map, required: true
  attr :file, :any, required: true

  defp file_listing(assigns) do
    assigns = assign(assigns, ancestors: [assigns.listing.path | assigns.ancestors])

    assigns =
      assign(
        assigns,
        :entries,
        assigns.listing.entries
        |> Enum.reject(&(&1.name == ".git" or (&1.ignored? && !assigns.show_ignored?)))
        |> Enum.sort_by(&{!file_directory?(&1), String.downcase(&1.name)})
      )

    ~H"""
    <ul class="file-list">
      <li :for={entry <- @entries}>
        <% path = entry.directory_target || Path.join(@listing.path, entry.name) %>
        <% directory? = file_directory?(entry) %>
        <% cycle? = path in @ancestors %>
        <% child = @directories[path] %>
        <button
          type="button"
          class={["workspace-file", @file && @file.path == path && "selected"]}
          disabled={cycle? || (entry.type in ["symlink", "link"] && !directory?)}
          phx-click={if directory?, do: "directory", else: "file"}
          phx-value-path={path}
          aria-expanded={if directory?, do: to_string(child != nil && !cycle?)}
          aria-current={if @file && @file.path == path, do: "true"}
          title={if entry.target, do: path <> " → " <> entry.target, else: path}
        >
          <span class="file-disclosure"><.icon
            :if={directory?}
            name="chevron"
            open={child != nil}
            size={12}
          /></span>
          <% {glyph, kind} = file_icon(entry) %>
          <span class={"file-kind kind-#{kind}"} data-kind={kind} aria-hidden="true"><.icon
            name={glyph}
            size={14}
          /></span>
          <span class="file-name">{entry.name}<span :if={entry.target}> → {entry.target}</span></span>
        </button>
        <.file_listing
          :if={is_struct(child, Files.Listing) && !cycle?}
          listing={child}
          ancestors={@ancestors}
          show_ignored?={@show_ignored?}
          directories={@directories}
          file={@file}
        />
        <p :if={match?({:loading, _}, child)} class="file-note" role="status">Loading…</p>
        <p :if={match?({:error, _}, child)} class="file-note" role="alert">{elem(child, 1)}</p>
      </li>
      <li :if={@entries == []} class="file-note">Empty directory</li>
      <li :if={@listing.truncated} class="file-note">Directory listing is truncated.</li>
    </ul>
    """
  end

  defp file_directory?(%{type: "directory"}), do: true
  defp file_directory?(entry), do: is_binary(entry.directory_target)

  # What kind of file an entry is, as the glyph and the colour class the tree
  # draws it with. A name the person would recognise at a glance --- a
  # Dockerfile, a lock file, a dotfile --- is matched before its extension,
  # so `mix.lock` is a lock and not "something ending in .lock". Colours are
  # theme tokens (see `.file-kind` in app.css), so every palette recolours
  # them and none of them is a hex value that one palette cannot read.
  @file_names %{
    "dockerfile" => {"container", "docker"},
    "containerfile" => {"container", "docker"},
    "docker-compose.yml" => {"container", "docker"},
    "docker-compose.yaml" => {"container", "docker"},
    "compose.yml" => {"container", "docker"},
    "compose.yaml" => {"container", "docker"},
    "package-lock.json" => {"lock", "lock"},
    "npm-shrinkwrap.json" => {"lock", "lock"},
    "bun.lockb" => {"lock", "lock"}
  }

  @file_extensions %{
    ".ex" => {"drop", "elixir"},
    ".exs" => {"drop", "elixir"},
    ".heex" => {"drop", "elixir"},
    ".eex" => {"drop", "elixir"},
    ".js" => {"code", "script"},
    ".jsx" => {"code", "script"},
    ".mjs" => {"code", "script"},
    ".cjs" => {"code", "script"},
    ".ts" => {"code", "typescript"},
    ".tsx" => {"code", "typescript"},
    ".mts" => {"code", "typescript"},
    ".json" => {"braces", "json"},
    ".md" => {"markdown", "markdown"},
    ".mdx" => {"markdown", "markdown"},
    ".css" => {"hash", "style"},
    ".scss" => {"hash", "style"},
    ".sass" => {"hash", "style"},
    ".less" => {"hash", "style"},
    ".html" => {"angles", "markup"},
    ".htm" => {"angles", "markup"},
    ".xml" => {"angles", "markup"},
    ".yml" => {"list", "yaml"},
    ".yaml" => {"list", "yaml"},
    ".toml" => {"list", "yaml"},
    ".lock" => {"lock", "lock"},
    ".png" => {"picture", "image"},
    ".jpg" => {"picture", "image"},
    ".jpeg" => {"picture", "image"},
    ".gif" => {"picture", "image"},
    ".svg" => {"picture", "image"},
    ".webp" => {"picture", "image"},
    ".ico" => {"picture", "image"},
    ".sh" => {"terminal", "shell"},
    ".bash" => {"terminal", "shell"},
    ".zsh" => {"terminal", "shell"},
    ".py" => {"code", "code"},
    ".rb" => {"code", "code"},
    ".rs" => {"code", "code"},
    ".go" => {"code", "code"},
    ".txt" => {"document", "text"},
    ".rst" => {"document", "text"},
    ".pdf" => {"document", "text"}
  }

  @doc false
  def file_icon(%{type: "directory"}), do: {"folder", "folder"}
  def file_icon(%{type: type}) when type in ["symlink", "link"], do: {"external", "link"}

  def file_icon(%{name: name}) do
    lower = String.downcase(name)
    extension = Path.extname(lower)

    cond do
      Map.has_key?(@file_names, lower) -> @file_names[lower]
      String.starts_with?(lower, "dockerfile") -> {"container", "docker"}
      Map.has_key?(@file_extensions, extension) -> @file_extensions[extension]
      # `.gitignore`, `.env`: a name that is all extension is a dotfile.
      String.starts_with?(lower, ".") -> {"dot-file", "dotfile"}
      true -> {"file", "file"}
    end
  end

  # Whether the Changes tab is showing one file's diff, which is when the
  # inspector widens for it (`.inspector.diff-open` in app.css).
  defp diff_open?(%Panel{tab: :changes, data: %Diff{files: files}}, path) when is_binary(path),
    do: Enum.any?(files, &(&1.change.path == path))

  defp diff_open?(_panel, _path), do: false

  defp diff_directory(path),
    do: if(Path.dirname(path) == ".", do: "", else: Path.dirname(path) <> "/")

  defp large_diff?(file),
    do:
      Enum.reduce(file.hunks, 0, &(length(&1.lines) + &2)) > 1000 or
        Enum.any?(file.hunks, fn hunk -> Enum.any?(hunk.lines, &(byte_size(&1.text) > 20_000)) end)

  # A turn ending is the moment the worktree stops moving, so it is when the
  # Changes list is worth re-reading -- in place, because somebody may be
  # reading the list or a diff in it. Only Changes: re-reading All files
  # would fold every directory somebody opened, and Checks follow a push
  # rather than a turn. Any other tab keeps what it shows, and the Changes
  # badge forgets its count rather than keep one the turn may have made
  # wrong; it comes back the next time the list is read. No polling, and no
  # read the page was not already going to make.
  #
  # A turn starting is the machine awake, so a pane or a Git status it had
  # refused as asleep is read again (RAV-91): until then `@turn` says
  # Working over the refusal, and afterwards the refusal is not left to call
  # the machine asleep again.
  defp after_turn(
         socket,
         %TranscriptEvent{kind: :stage, stage: "turn", state: "started"}
       ),
       do: reread_refused(socket, %{available: true})

  defp after_turn(socket, %TranscriptEvent{} = event) do
    cond do
      not TranscriptEvent.settles?(event) ->
        socket

      socket.assigns.panel.tab == :changes ->
        load_panel(socket, &Panel.reloading/1)

      socket.assigns.panel.tab == :checks ->
        socket |> update_panel(&Panel.forget_changes/1) |> load_git()

      true ->
        update_panel(socket, &Panel.forget_changes/1)
    end
  end

  defp workspace_async(socket, name, fun) do
    %{current_user: user, track_id: id} = socket.assigns

    traced_async(socket, name, fn ->
      identity = Tracks.machine_identity(user, id)
      {:workspace, identity, if(elem(identity, 0) == :ok, do: fun.(), else: {:error, :not_found})}
    end)
  end

  # An asleep panel waits for a wake signal or explicit refresh, never a timer.
  defp asleep_panel(socket),
    do:
      update_panel(
        socket,
        &(Panel.loading(&1)
          |> Panel.loaded(:machine_asleep)
          |> Panel.close_file()
          |> Panel.forget_cache())
      )

  defp reload_panel(socket), do: socket |> update_panel(&Panel.loading/1) |> load_panel()

  defp load_panel(socket, mark \\ &Panel.loading/1)
  defp load_panel(%{assigns: %{panel: %{data: :machine_asleep}}} = socket, _mark), do: socket

  defp load_panel(socket, mark) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    tab = socket.assigns.panel.tab

    # Git status is read beside the checks rather than inside them, so
    # GitHub being down does not hide what the machine holds, or the reverse.
    socket = if tab == :checks, do: load_git(socket), else: socket

    socket
    |> update_panel(mark)
    |> workspace_async({:panel, tab}, fn ->
      case tab do
        :files -> Tracks.files(user, id, nil)
        :changes -> load_changes(user, id)
        :checks -> Tracks.checks(user, id)
        :preview -> Previews.status(user, id)
      end
    end)
  end

  defp enrich_listing(panel, path, {:ok, {:ok, %Files.Listing{path: path} = listing}}) do
    cond do
      match?(%Files.Listing{path: ^path}, panel.data) ->
        %{panel | data: listing}

      is_struct(panel.directories[path], Files.Listing) ->
        %{panel | directories: Map.put(panel.directories, path, listing)}

      true ->
        panel
    end
  end

  defp enrich_listing(panel, _path, _response), do: panel

  defp load_file_metadata(socket, listing) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    token = make_ref()

    socket
    |> update_panel(&%{&1 | metadata: Map.put(&1.metadata, listing.path, token)})
    |> workspace_async({:file_metadata, listing.path, token}, fn ->
      Tracks.file_metadata(user, id, listing)
    end)
  end

  # Only an empty diff needs GitHub to distinguish untouched work from a
  # merged branch. A GitHub outage must not hide the worktree diff.
  defp load_changes(user, id) do
    with {:ok, diff} <- Tracks.diff(user, id) do
      merged? =
        diff.diff == "" &&
          match?({:ok, %ChecksReport{pull: %{state: :merged}}}, Tracks.checks(user, id))

      {:ok, {diff, merged?}}
    end
  end

  defp update_panel(socket, fun),
    do: socket |> assign(panel: fun.(socket.assigns.panel)) |> assign_turn()

  defp queue_label(:queued), do: "Queued"
  defp queue_label(:sending), do: "Sending…"
  defp queue_label(:failed), do: "Needs attention"
  defp queue_label(:unconfirmed), do: "Not confirmed"

  defp queued(socket, call, id, on_ok \\ & &1) do
    response = call.(socket.assigns.current_user, socket.assigns.track_id, id)
    result(socket, response, fn s, _ -> s |> refresh_queue() |> on_ok.() end)
  end

  # What each event can actually have changed for the track on screen.
  #
  # `:here` is who is looking, and nothing else. `:queue` is the queue.
  # Everything else lands in the track's own detail: its status and turn
  # count (`:turn`), its people (`:people`), its title and whether it is
  # still open (`:tracks`), and whether the project moved out from under it
  # (`:settings`, which is what `stale` compares).
  #
  # Only `:turn` re-reads the transcript. The transcript arrives on the
  # follower's stream, not on the hub, so re-reading it is a repair for a
  # gap rather than the way it is kept current -- and a turn beginning or
  # failing is the one hub event that means the stream may have missed
  # something.
  defp hub(%Event{name: :here, present: present}, socket),
    do: assign(socket, present: present)

  defp hub(%Event{name: :queue}, socket), do: refresh_queue(socket)

  defp hub(%Event{name: :turn, thread_id: thread_id}, socket),
    do:
      socket
      |> drop_thread_state(thread_id)
      |> refresh_detail()
      |> refresh_queue()
      |> catch_up_transcript()

  # Sleep is on the row; the conversations can come from the memo.
  defp hub(%Event{name: :machine}, socket), do: refresh_detail(socket, fresh: false)

  defp hub(%Event{name: name}, socket) when name in [:people, :tracks, :settings] do
    # The Share dialog lists whom the track is shared with; somebody else
    # sharing or unsharing it changes that under an open dialog.
    if name == :people and socket.assigns[:dialog] == :people do
      if Ravix.People.workspace_sharing?(socket.assigns.project || %{}),
        do: send_update(RavixWeb.Live.ShareDialog, id: "track-share", reload: true),
        else: send_update(RavixWeb.Live.PeopleDialog, id: "track-people", reload: true)
    end

    socket |> refresh_detail() |> refresh_plan_items()
  end

  # Somebody's read mark moved. This page is the one that moves it, and it
  # draws nothing from it: the unread dot is the rail's, and the rail clears
  # its own. Not a reason to re-read the detail, which is two Fountain round
  # trips, on every load, stage and send of every other page on this track.
  defp hub(%Event{name: :read}, socket), do: socket

  # An Inbox excerpt was kept; this page reads the transcript itself.
  defp hub(%Event{name: :reply}, socket), do: socket

  # A comment on the shown thread is drawn and, since this person is looking
  # at it, read. One on a sibling thread moves only that tab's dot.
  defp hub(%Event{name: :comment, thread_id: thread_id}, socket) do
    if thread_id == socket.assigns.thread_id do
      Tracks.mark_read(socket.assigns.current_user, socket.assigns.track_id, thread_id)
      load_comments(socket)
    else
      refresh_detail(socket)
    end
  end

  # The configuration form always shows what would actually be used --- the
  # track's override if it has one, the project's default otherwise --- so
  # it is rebuilt whenever the preview is, rather than being a box somebody
  # typed in once. Rebuilding also clears a refusal from the last attempt.
  defp show_preview(socket, %Previews.View{} = preview) do
    config = preview.config || %{}

    assign(socket,
      preview: preview,
      preview_url: if(preview.url, do: socket.assigns.preview_url),
      preview_form:
        Form.new(:preview_config, %{
          "directory" => Map.get(config, :directory, "."),
          "command" => Map.get(config, :command, ""),
          "readiness_path" => Map.get(config, :readiness_path, ""),
          "stop_command" => Map.get(config, :stop_command, "")
        })
    )
  end

  # The three refreshes below all run off a message --- a hub event, a stage
  # event on the transcript, the backstop tick --- and none of them may be
  # run in this process. `Tracks.get/2` alone is two Fountain round trips, so
  # a page that did it inline stopped rendering, stopped answering clicks and
  # stopped taking transcript events for as long as Fountain took to answer,
  # on every event of a turn.
  #
  # Naming each one also fixes what a burst does to the screen. A second
  # `start_async/3` under the same name supersedes the first, and LiveView
  # drops the superseded answer rather than delivering it, so a stage event
  # arriving mid-read cannot render a detail older than the one after it. The
  # superseded read itself still runs; what keeps a burst from costing a call
  # per event is the memo behind `Tracks.get/2`, not this.
  defp refresh_detail(socket, opts \\ [fresh: true])
  defp refresh_detail(%{assigns: %{track: nil}} = socket, _opts), do: socket

  defp refresh_detail(socket, opts) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    thread_id = socket.assigns.thread_id

    generation = socket.assigns.thread_generation

    traced_async(socket, {:detail, thread_id, generation}, fn ->
      Tracks.get(user, id, fresh: Keyword.fetch!(opts, :fresh), thread_id: thread_id)
    end)
  end

  defp visible_plan(user, %{id: id} = plan) do
    if match?({:ok, _, _}, Ravix.Plans.access(user, id)), do: plan
  end

  defp visible_plan(_user, nil), do: nil

  defp refresh_plan_items(socket) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    traced_async(socket, {:plan_items, id}, fn -> Ravix.Plans.track_summary(user, id) end)
  end

  defp refresh_queue(socket) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    thread_id = socket.assigns.thread_id
    traced_async(socket, :queue, fn -> PromptQueue.list(user, id, thread_id) end)
  end

  # Whether this person still reaches this track: read afresh, every time it
  # is called. `guard/2` is what decides how often that is.
  defp authorized?(socket) do
    case Access.track_access(socket.assigns.current_user, socket.assigns.track_id) do
      {:ok, %{track: track}} ->
        track.project_id == socket.assigns.project_id and is_nil(track.closed_at)

      _ ->
        false
    end
  end

  # The answer this page holds between reads. It is re-read when the project's
  # hub says the people or the tracks changed -- which is every way access to
  # a track can be taken away, and is the contract `Ravix.Tracks.Follower`
  # already documents for the transcript stream -- and, as a backstop against
  # a notice going missing on a partition, when it is old. See
  # `RavixWeb.Live.Guard`; the session half of the question is that hook's,
  # and has already run by the time this does.
  defp guard(socket, message \\ nil) do
    held = Guard.observe(message, socket.assigns.track_guard, socket.assigns.track_id)

    if Guard.holds?(held) do
      {:cont, assign(socket, track_guard: held)}
    else
      if authorized?(socket) do
        {:cont, assign(socket, track_guard: renew(socket))}
      else
        {:halt, redirect(socket, to: "/")}
      end
    end
  end

  # The track answer runs out no later than the session behind it does.
  defp renew(socket), do: Guard.new(socket.assigns.session_hash, expiry(socket))

  defp expiry(socket) do
    case socket.assigns[:session_guard] do
      %Guard{expires_at: %DateTime{} = at} -> at
      _ -> nil
    end
  end

  defp owner_or_creator?(user, track),
    do: Access.creator?(user, track) or (track.visibility == :project and track.role == :owner)

  # What deleting a dedicated track's machine would take with it, as
  # `Tracks.close_info/2` found it; shared by the Close and Rebuild dialogs.
  attr :id, :string, required: true
  attr :info, :any, required: true

  defp machine_changes(assigns) do
    ~H"""
    <p id={@id}>
      <%= case @info do %>
        <% nil -> %>
          Checking for uncommitted changes and unpushed commits…
        <% :unavailable -> %>
          The machine could not be checked. It may contain uncommitted changes or unpushed commits.
        <% info -> %>
          {if info.dirty,
            do: "Uncommitted changes will be deleted.",
            else: "No uncommitted changes found."}
          <%= case info.unpushed do %>
            <% :unknown -> %>
              Unpushed commits could not be checked. The branch may have no upstream, or the check may have failed.
            <% true -> %>
              Unpushed commits will be deleted.
            <% false -> %>
              No unpushed commits found.
          <% end %>
      <% end %>
    </p>
    """
  end

  # Only a track on its own machine can be rebuilt on its own. It is offered
  # from the header while that machine is ready, and called out in the setup
  # banner when secrets changed under it, the one case that needs a rebuild.
  defp rebuildable?(user, track) do
    track.sandbox_layout == :dedicated and owner_or_creator?(user, track) and
      (track.setup_error_code == "secrets_changed" or
         (Ravix.Config.dedicated_opens_enabled?(user) and track.sandbox_state == :ready))
  end

  # The markdown of every block on the page, rendered once per body.
  #
  # A text block's body only ever grows --- `push_text/4` appends the next
  # chunk to it --- so the same body is the same HTML, and a body that has
  # changed is a key that is not here yet. The map is rebuilt from the page
  # rather than added to, so a turn that was re-read and came back shorter
  # takes its old renderings away with it and nothing accumulates.
  #
  # What it saves is the whole of a turn on every draw of it. Inserting a
  # turn renders all of its blocks, so a settled tool call from an hour ago
  # was re-parsed once per window of the reply still being written
  # underneath it, and a repair re-parsed the entire transcript to find that
  # nothing in it had changed. `block/1` renders anything missing here for
  # itself, so a miss is slower and never wrong.
  defp memoize(socket) do
    previous = socket.assigns.rendered

    rendered =
      for turn <- socket.assigns.page.turns,
          block <- turn.blocks,
          markdown?(block),
          into: %{},
          do:
            {block.body,
             Map.get_lazy(previous, block.body, fn -> Markdown.render_safe(block.body) end)}

    assign(socket, rendered: rendered)
  end

  defp markdown?(%TranscriptBlock.Text{}), do: true
  defp markdown?(%TranscriptBlock.Thinking{}), do: true
  defp markdown?(_block), do: false

  defp rendered(cache, %TranscriptBlock.Text{body: body}), do: Map.get(cache, body)
  defp rendered(cache, %TranscriptBlock.Thinking{body: body}), do: Map.get(cache, body)
  defp rendered(_cache, _block), do: nil

  # A turn reads as its answer, with the work that led there folded into one
  # line above it. Everything up to the last tool call or thought is that
  # work, including the running commentary between calls; whatever follows
  # it is the answer and stays open. A plan or a failure is never folded
  # away, since each is news in its own right, so it is drawn after the fold
  # in the order it arrived.
  defp segments(blocks) do
    case last_work_index(blocks) do
      nil ->
        Enum.map(blocks, &{:block, &1})

      index ->
        {head, answer} = Enum.split(blocks, index + 1)
        {work, kept} = Enum.split_with(head, &folds?/1)
        [{:work, work} | Enum.map(kept ++ answer, &{:block, &1})]
    end
  end

  defp last_work_index(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {block, index}, found -> if work?(block), do: index, else: found end)
  end

  defp work?(%TranscriptBlock.Tool{}), do: true
  defp work?(%TranscriptBlock.Thinking{}), do: true
  defp work?(_block), do: false

  defp folds?(%TranscriptBlock.Plan{}), do: false
  defp folds?(%TranscriptBlock.Failure{}), do: false
  defp folds?(%TranscriptBlock.System{}), do: false
  defp folds?(_block), do: true

  attr :blocks, :list, required: true
  attr :rendered, :map, required: true
  attr :turn, :map, required: true
  attr :workdir, :string, default: nil

  # `open` is the reader's: the server never sets it, and ignoring it keeps a
  # patch to a live turn from closing the fold somebody just opened. That
  # only holds for an element the patch keeps, and LiveView matches elements
  # by `id`, falling back to a render-scoped `data-phx-id` that a turn's
  # re-insert changes; so the fold, the thoughts and every call carry an id.
  #
  # The turn's thoughts are one toggle at the head of the fold rather than a
  # row between every call. Agents think between nearly every pair of calls,
  # so merging only adjacent thoughts would still leave one in every other
  # row, and the calls are what a reader scans the fold for. Inside the
  # toggle they keep their order.
  defp work(assigns) do
    {thoughts, rows} = Enum.split_with(assigns.blocks, &match?(%TranscriptBlock.Thinking{}, &1))
    tools = for %TranscriptBlock.Tool{} = tool <- rows, do: tool

    # No failure count on the folded line: agents usually recover from a
    # failing tool call, and a red "N failed" reads as the turn failing. A
    # turn that really fails says so with its own failure block; each call's
    # own status is still inside the fold, in the same muted tone.
    now = tools |> Enum.reverse() |> Enum.find(&(&1.status == :running))

    assigns =
      assign(assigns,
        label: work_label(assigns.blocks, length(tools)),
        kinds: work_kinds(tools),
        now: now && running(now, assigns.workdir),
        thoughts: thoughts,
        rows: rows
      )

    ~H"""
    <details
      id={"work-#{@turn.id}"}
      class="workspace-work"
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary>
        <.disclosure_chevron />
        <span :if={@label != ""}>{@label}</span>
        <span :if={@kinds != []} class="work-kinds">
          <.icon :for={{icon, word} <- @kinds} name={icon} size={13} data-kind={word} />
          <span class="sr-only">Used: {Enum.map_join(@kinds, ", ", &elem(&1, 1))}</span>
        </span>
        <span :if={@now} class="work-now">{@now}</span>
      </summary>
      <div class="workspace-work-body">
        <details
          :if={@thoughts != []}
          id={"thoughts-#{@turn.id}"}
          class="workspace-thinking"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary>
            <.disclosure_chevron />
            <span>{counted(length(@thoughts), "thought")}</span>
          </summary>
          <.block :for={thought <- @thoughts} block={thought} html={rendered(@rendered, thought)} />
        </details>
        <div :for={{block, index} <- Enum.with_index(@rows)}>
          <.block
            block={block}
            html={rendered(@rendered, block)}
            workdir={@workdir}
            id={"work-#{@turn.id}-#{index}"}
          />
        </div>
      </div>
    </details>
    """
  end

  # The folded line's "now": the running call as its row names it.
  defp running(tool, workdir) do
    case ToolCall.first_line(ToolCall.target(tool), workdir) do
      {nil, _more} -> ToolCall.label(tool)
      {line, _more} -> "#{ToolCall.label(tool)} #{line}"
    end
  end

  # Thoughts are counted on their own toggle inside the fold, not on this
  # line, unless they are all the fold holds and the line would say nothing.
  defp work_label(blocks, tools) do
    [
      counted(tools, "tool call"),
      counted(Enum.count(blocks, &match?(%TranscriptBlock.Text{}, &1)), "message")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> counted(Enum.count(blocks, &match?(%TranscriptBlock.Thinking{}, &1)), "thought") || ""
      counts -> Enum.join(counts, ", ")
    end
  end

  # The distinct kinds of work the calls did, in the order each was first
  # used, capped so the line stays a glance.
  @work_kinds 4
  defp work_kinds(tools) do
    tools
    |> Enum.map(&ToolCall.summary_kind/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@work_kinds)
  end

  defp counted(0, _noun), do: nil
  defp counted(1, noun), do: "1 #{noun}"
  defp counted(n, noun), do: "#{n} #{noun}s"

  attr :id, :string, required: true
  attr :turn, :map, required: true
  attr :link, :string, required: true
  attr :workdir, :string, default: nil
  attr :options, :list, default: nil
  attr :zone, :string, default: nil

  # What a finished turn cost and left behind: the answer to copy and a ⋯
  # menu, how long it ran, when it ended, the files its edits touched, and
  # the effort and Fast it ran with (RAV-52). The time is the viewer's own
  # (`RavixWeb.CoreComponents.local_time/1`), with a weekday when it was not
  # today. The actions come first so the copy icon sits where the running
  # turn's spinner sat, whatever the times beside it say (RAV-93).
  #
  # The menu is "Copy link to turn" and "Copy text", and nothing else: the
  # owner's decision for RAV-93. Retry stays where it is, above the footer.
  # Both items copy in the browser (`assets/js/hooks/transcript_tail.js`);
  # neither sends anything to the server.
  defp turn_footer(assigns) do
    %{turn: turn, workdir: workdir} = assigns
    config = SessionConfig.describe(turn.config_selection, assigns.options)
    {started, ended} = turn_span(turn.events)
    files = changed_files(turn.blocks, workdir)
    {shown, rest} = Enum.split(files, 2)

    assigns =
      assign(assigns,
        duration: started && ended && duration(DateTime.diff(ended, started)),
        ended: ended,
        answer: answer(turn.blocks),
        shown: shown,
        rest: rest,
        applied: config.applied,
        skipped: config.skipped
      )

    ~H"""
    <footer class="turn-footer">
      <span class="turn-actions">
        <button
          :if={@answer != ""}
          type="button"
          class="ghost turn-copy"
          aria-label="Copy answer"
          data-tip="Copy answer"
          data-copy={@answer}
        >
          <.icon name="copy" size={13} />
        </button>
        <div id={@id <> "-more"} class="chip-menu" phx-hook="ChipMenu">
          <button
            type="button"
            id={@id <> "-more-trigger"}
            class="ghost turn-more"
            popovertarget={@id <> "-more-menu"}
            aria-haspopup="menu"
            aria-expanded="false"
            aria-controls={@id <> "-more-menu"}
            aria-label="More for this turn"
            data-tip="More"
            phx-mounted={JS.ignore_attributes(["aria-expanded"])}
            style={"anchor-name: --#{@id}-more"}
          >
            <.icon name="more" size={13} />
          </button>
          <div
            id={@id <> "-more-menu"}
            class="chip-popover-below turn-menu"
            popover
            role="menu"
            aria-label="More for this turn"
            style={"position-anchor: --#{@id}-more"}
          >
            <button
              type="button"
              class="account-item"
              role="menuitem"
              data-chip-close
              data-copy-link={@link}
            >
              <span class="menu-check" aria-hidden="true"><.icon name="link" size={14} /></span>Copy link to turn
            </button>
            <button
              type="button"
              class="account-item"
              role="menuitem"
              data-chip-close
              data-copy-text={@answer}
              disabled={@answer == ""}
            >
              <span class="menu-check" aria-hidden="true"><.icon name="copy" size={14} /></span>Copy text
            </button>
          </div>
        </div>
      </span>
      <span :if={@applied != []} class="turn-config" title="Settings this turn ran with">
        {Enum.join(@applied, " · ")}
      </span>
      <span :if={@applied != []} aria-hidden="true">·</span>
      <span :if={@duration} class="turn-duration">{@duration}</span>
      <span :if={@duration && @ended} aria-hidden="true">·</span>
      <.local_time
        :if={@ended}
        id={@id <> "-ended"}
        at={@ended}
        zone={@zone}
        title_prefix="Ended "
        weekday
      />
      <span :for={file <- @shown} class="turn-file" title={file.path}>
        {Path.basename(file.path)}
        <span class="diff-add">+{file.added}</span> <span class="diff-del">−{file.removed}</span>
      </span>
      <span
        :if={@rest != []}
        class="turn-file"
        title={Enum.map_join(@rest, "\n", & &1.path)}
      >
        +{length(@rest)} more <span class="diff-add">+{Enum.sum_by(@rest, & &1.added)}</span>
        <span class="diff-del">−{Enum.sum_by(@rest, & &1.removed)}</span>
      </span>
      <span :if={@skipped != []} class="turn-config-skipped">
        {Enum.join(@skipped, ", ")} skipped: this model doesn't offer {if length(@skipped) == 1,
          do: "it",
          else: "them"}
      </span>
    </footer>
    """
  end

  attr :turn, :map, required: true
  attr :zone, :string, default: nil

  # How long a running turn has been going, as the live turn's last line: a
  # spinner, where the finished footer's copy icon will be, and the time in
  # tenths of a second (RAV-93). The server writes the elapsed time as of
  # this render; `assets/js/hooks/turn_timer.js` keeps it ticking from
  # `data-started` without a round-trip, correcting the browser's clock by
  # `data-now`. Settling swaps this for `turn_footer/1`'s final duration.
  defp turn_timer(assigns) do
    {started, _ended} = turn_span(assigns.turn.events)
    now = DateTime.utc_now()
    assigns = assign(assigns, started: started, now: now)

    ~H"""
    <footer :if={@started} class="turn-footer turn-running">
      <span class="turn-spinner" aria-hidden="true"><.icon name="spinner" size={13} /></span>
      <span
        id={"turn-timer-#{@turn.id}"}
        class="turn-elapsed"
        phx-hook="TurnTimer"
        data-started={DateTime.to_iso8601(@started)}
        data-now={DateTime.to_iso8601(@now)}
        title={"Running since #{RavixWeb.LocalTime.full(@started, @zone)}"}
      >{running_duration(DateTime.diff(@now, @started, :millisecond))}</span>
    </footer>
    """
  end

  # A running turn's time: tenths of a second for the first minute, then as
  # `duration/1` writes a settled one. `formatDuration` in the hook matches.
  @doc false
  def running_duration(ms) when ms < 60_000 do
    tenths = div(max(ms, 0), 100)
    "#{div(tenths, 10)}.#{rem(tenths, 10)}s"
  end

  def running_duration(ms), do: duration(div(ms, 1000))

  # The page that opens this turn: its track and thread, and the turn's own
  # element as the fragment, which `TranscriptTail` scrolls to once it is
  # drawn. Access is checked on the way in, as for any other URL.
  defp turn_link(track, thread_id, dom_id),
    do: "/p/#{track.project_id}/t/#{track.id}?thread=#{thread_id}##{dom_id}"

  # Events are newest first. The turn opened at its `started` stage (or its
  # oldest event, for a turn Fountain started itself) and ended at the stage
  # that settled it.
  defp turn_span(events) do
    opened = Enum.find(events, &TranscriptEvent.starts_turn?/1) || List.last(events)
    closed = Enum.find(events, &TranscriptEvent.settles?/1)
    {timestamp(opened), timestamp(closed)}
  end

  defp timestamp(%TranscriptEvent{ts: ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp timestamp(_event), do: nil

  defp duration(seconds) when seconds < 60, do: "#{max(seconds, 0)}s"
  defp duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  # The answer is what `segments/1` leaves open after the work.
  defp answer(blocks) do
    blocks
    |> segments()
    |> Enum.flat_map(fn
      {:block, %TranscriptBlock.Text{body: body}} -> [String.trim(body)]
      _segment -> []
    end)
    |> Enum.join("\n\n")
  end

  # Every file an edit in this turn touched, once, with its lines summed,
  # named relative to the track's directory.
  defp changed_files(blocks, workdir) do
    prefix = if is_binary(workdir), do: String.trim_trailing(workdir, "/") <> "/", else: nil

    blocks
    |> Enum.flat_map(fn
      %TranscriptBlock.Tool{detail: detail} -> detail.edits
      _block -> []
    end)
    |> Enum.reject(&(&1.path == ""))
    |> Enum.group_by(&relative(&1.path, prefix))
    |> Enum.map(fn {path, edits} ->
      %{
        path: path,
        added: Enum.sum_by(edits, & &1.added),
        removed: Enum.sum_by(edits, & &1.removed)
      }
    end)
    |> Enum.sort_by(& &1.path)
  end

  defp relative(path, nil), do: path

  defp relative(path, prefix),
    do:
      if(String.starts_with?(path, prefix),
        do: String.replace_prefix(path, prefix, ""),
        else: path
      )

  # One head per block struct, rather than five `:if` comparisons against a
  # `:kind` field the blocks no longer carry. A block shape added to
  # `Ravix.Tracks.Transcript.Block` and not drawn here is a
  # `FunctionClauseError` on the page that would have rendered it silently
  # blank, which is the trade this conversion was for.
  attr :block, :map, required: true
  attr :html, :any, default: nil, doc: "this body's markdown, if `memoize/1` has it"
  attr :workdir, :string, default: nil, doc: "the track directory tool rows name paths from"
  attr :id, :string, default: nil, doc: "a tool row's DOM id, stable across patches"

  defp block(%{block: %TranscriptBlock.Text{}} = assigns) do
    ~H"""
    <div class="md">{@html || Markdown.render_safe(@block.body)}</div>
    """
  end

  # One thought, as `work/1` lists them inside the turn's thoughts toggle.
  defp block(%{block: %TranscriptBlock.Thinking{}} = assigns) do
    ~H"""
    <div class="md">{@html || Markdown.render_safe(@block.body)}</div>
    """
  end

  defp block(%{block: %TranscriptBlock.Raw{}} = assigns) do
    ~H"""
    <pre>{@block.body}</pre>
    """
  end

  defp block(%{block: %TranscriptBlock.System{}} = assigns) do
    ~H"""
    <div class="workspace-system-card" role="status">
      <strong>Session restarted</strong>
      <p>{@block.body}</p>
    </div>
    """
  end

  defp block(%{block: %TranscriptBlock.Failure{}} = assigns) do
    ~H"""
    <div class="workspace-failure" role="status">
      <strong>{Transcript.failure_label(@block.stage)}</strong>
      <p :if={@block.body != ""}>{Ravix.Fountain.Error.reason_message(@block.body)}</p>
      <p>{Transcript.failure_next_step(@block)}</p>
      <button
        :if={@block.stage == "config"}
        type="button"
        class="ghost"
        popovertarget="model-menu"
      >Change setting</button>
      <details :if={@block.body != ""} class="failure-details">
        <summary><.disclosure_chevron /> Technical details</summary>
        <pre>{@block.details || @block.body}</pre>
      </details>
    </div>
    """
  end

  defp block(%{block: %TranscriptBlock.Tool{}} = assigns) do
    ~H"""
    <ToolCall.tool_call id={@id} block={@block} workdir={@workdir} />
    """
  end

  # The checklist the agent is working from, as it last stood. The marker is
  # a labelled image rather than a color, so the state reads without either.
  defp block(%{block: %TranscriptBlock.Plan{}} = assigns) do
    ~H"""
    <div class="workspace-plan" role="group" aria-label="Plan">
      <strong>Plan</strong>
      <ol>
        <li :for={entry <- @block.entries} class={"plan-#{entry.status}"}>
          <span class="plan-mark" role="img" aria-label={plan_status(entry.status)}>
            {plan_mark(entry.status)}
          </span>
          <span>{entry.content}</span>
        </li>
      </ol>
    </div>
    """
  end

  defp plan_mark(:completed), do: "✓"
  defp plan_mark(:in_progress), do: "▸"
  defp plan_mark(:pending), do: "○"

  defp plan_status(:completed), do: "done"
  defp plan_status(:in_progress), do: "in progress"
  defp plan_status(:pending), do: "to do"

  attr :prompt, :string, required: true
  attr :image_count, :integer, required: true
  attr :track_id, :string, required: true
  attr :thread_id, :string, required: true
  attr :turn_id, :string, required: true

  defp prompt_message(assigns) do
    {speaker, body, restored?} = visible_prompt(assigns.prompt)
    assigns = assign(assigns, speaker: speaker, body: body, restored?: restored?)

    ~H"""
    <div class="said">
      <span class="speaker">{@speaker}</span>
      <span :if={@restored?} class="chip">Context restored</span>
      <div :if={@body != ""} class="workspace-prompt md">{prompt_html(@body)}</div>
      <div :if={@image_count > 0} class="prompt-images" role="group" aria-label="Attached images">
        <a
          :for={position <- 0..(@image_count - 1)}
          href={~p"/tracks/#{@track_id}/threads/#{@thread_id}/turns/#{@turn_id}/images/#{position}"}
          target="_blank"
          rel="noopener"
          aria-label={"Open attached image #{position + 1} in a new tab"}
          data-tip={"Open attached image #{position + 1} in a new tab"}
        >
          <img
            src={~p"/tracks/#{@track_id}/threads/#{@thread_id}/turns/#{@turn_id}/images/#{position}"}
            alt={"Attached image #{position + 1}"}
            loading="lazy"
            width="160"
            height="120"
          />
        </a>
      </div>
    </div>
    """
  end

  # A person's note, drawn as neither a prompt (the bubble on the right) nor
  # a reply (the page on the left): a bordered card across the transcript,
  # labelled as a comment, with its author and time. The body is markdown
  # through the one escaping renderer. Edit and delete are the author's.
  attr :comment, :map, required: true
  attr :current_user, :map, required: true
  attr :editing, :any, default: nil
  attr :zone, :string, default: nil

  defp thread_comment(assigns) do
    comment = assigns.comment

    assigns =
      assign(assigns,
        login: (comment.author && comment.author.login) || "someone",
        deleted?: not is_nil(comment.deleted_at),
        mine?: comment.author_id == assigns.current_user.id,
        editing?: assigns.editing == comment.id and comment.author_id == assigns.current_user.id
      )

    ~H"""
    <aside
      id={"comment-#{@comment.id}"}
      class={["thread-comment", @deleted? && "deleted"]}
      aria-label={"Comment by @#{@login}"}
    >
      <header class="thread-comment-head">
        <.icon name="person" size={13} />
        <strong>@{@login}</strong>
        <span class="chip">Comment · not sent to the agent</span>
        <span class="spacer"></span>
        <.local_time
          id={"comment-#{@comment.id}-at"}
          at={@comment.inserted_at}
          zone={@zone}
        />
        <span :if={@comment.edited_at && !@deleted?} class="thread-comment-edited">edited</span>
      </header>
      <p :if={@deleted?} class="thread-comment-deleted">Comment deleted</p>
      <div :if={!@deleted? && !@editing?} class="md thread-comment-body">
        {Markdown.render_safe(@comment.body)}
      </div>
      <form
        :if={!@deleted? && @editing?}
        id={"comment-edit-#{@comment.id}"}
        class="thread-comment-edit"
        phx-submit="save-comment"
      >
        <input type="hidden" name="comment_id" value={@comment.id} />
        <textarea
          name="body"
          rows="3"
          maxlength={Ravix.Comments.Comment.max_body()}
          aria-label="Edit comment"
        >{@comment.body}</textarea>
        <div class="thread-comment-actions">
          <button type="submit" class="primary">Save</button>
          <button type="button" class="ghost" phx-click="cancel-comment-edit">Cancel</button>
        </div>
      </form>
      <div :if={@mine? && !@deleted? && !@editing?} class="thread-comment-actions">
        <button
          type="button"
          class="ghost"
          phx-click="edit-comment"
          phx-value-id={@comment.id}
          aria-label="Edit your comment"
        >
          Edit
        </button>
        <button
          type="button"
          class="ghost"
          phx-click="delete-comment"
          phx-value-id={@comment.id}
          data-confirm="Delete this comment?"
          aria-label="Delete your comment"
        >
          Delete
        </button>
      </div>
    </aside>
    """
  end

  # A prompt as its author meant it to be read: Ravix's delivery wrappers
  # and the author marker taken off, which the retry puts back into the
  # composer as typed and the transcript and queue draw.
  defp visible_prompt(prompt) do
    {prompt, restored?} = PromptQueue.visible_prompt(prompt)
    {speaker, body} = prompt_author(prompt)
    {speaker, body, restored?}
  end

  # A prompt is markdown as often as a reply is, whether a person or an
  # orchestrating agent wrote it, so it goes through the same escaping
  # renderer. Newlines stay breaks: people type prompts with plain ones.
  defp prompt_html(body), do: Markdown.render_safe(body, breaks: true)

  defp queue_prompt_html(prompt) do
    {_speaker, body, _restored?} = visible_prompt(prompt)
    prompt_html(body)
  end

  # Shared prompts carry PromptQueue.with_author/2's marker after the preview
  # instructions. Never infer an old, untagged message's author from its viewer.
  # An additional thread's working-directory line sits inside the author
  # marker, and is the agent's to read rather than anybody's to see.
  defp prompt_author(prompt) do
    case Regex.run(~r/\A\[from @([a-zA-Z0-9-]+)\] (.*)\z/s, prompt) do
      [_, login, body] -> {"@" <> login, PromptQueue.Body.outside_thread(body)}
      nil -> prompt |> PromptQueue.Body.outside_thread() |> app_or_unattributed_prompt()
    end
  end

  defp app_or_unattributed_prompt(prompt) do
    case Transcript.app_turn_label(prompt) do
      nil -> {"User", prompt}
      label -> {"Ravix", label}
    end
  end

  # The box says what it can do until somebody has used it; after the first
  # turn the conversation is under way and "a follow-up" is the honest word.
  # While a turn runs, the box asks for no more than the follow-up, which
  # waits for the turn (RAV-94).
  defp composer_placeholder(:comment, _page, _running?),
    do: "Comment for people on this thread, @mention someone"

  defp composer_placeholder(:ask, _page, true), do: "Add a follow up"

  defp composer_placeholder(:ask, page, false) do
    if Enum.any?(page.turns, & &1.visible?),
      do: "Add a follow-up, @mention files, run /commands",
      else: "Ask to make changes, @mention files, run /commands"
  end

  # The `/` menu: what the agent advertised, sent to it as the text of the
  # message, then the few Ravix actions that are already a button on this
  # page, which run that button's event instead of sending anything. Stop is
  # offered only while there is something to stop.
  defp composer_commands(agent_commands, running?, pending) do
    agent =
      Enum.map(
        agent_commands,
        &%{name: &1.name, description: &1.description, hint: &1.hint, source: "agent"}
      )

    stop =
      if running? and :interrupt not in pending,
        do: [%{name: "stop", description: "Stop the agent's current turn", event: "interrupt"}],
        else: []

    ravix =
      stop ++
        [
          %{name: "new", description: "Start a new thread", event: "draft-thread"},
          %{
            name: "comment",
            description: "Write a comment for people, not the agent",
            event: "composer-mode",
            value: %{mode: "comment"}
          },
          %{
            name: "changes",
            description: "Open the Changes tab",
            event: "panel",
            value: %{name: "changes"}
          },
          %{
            name: "checks",
            description: "Open the Checks tab",
            event: "panel",
            value: %{name: "checks"}
          }
        ]

    agent ++ Enum.map(ravix, &Map.put(&1, :source, "ravix"))
  end

  defp upload_error(:too_large), do: "Image is larger than 8 MB."
  defp upload_error(:too_many_files), do: "Attach at most six images."
  defp upload_error(_), do: "Use a PNG, JPEG, GIF, or WebP image."
end
