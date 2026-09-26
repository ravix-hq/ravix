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
  @dialogs %{"rename" => :rename, "close" => :close, "people" => :people, "pull" => :pull}

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

  alias Ravix.Accounts.Access
  alias Ravix.GitHub.ChecksReport
  alias Ravix.{Hub, Previews, PromptQueue, Tracks}
  alias Ravix.Hub.Event
  alias Ravix.Tracks.{Diff, Files, Follower}
  alias Ravix.Tracks.Transcript
  alias Ravix.Tracks.Transcript.Block, as: TranscriptBlock
  alias Ravix.Tracks.Transcript.Event, as: TranscriptEvent
  alias RavixWeb.Error
  alias RavixWeb.Live.Form
  alias RavixWeb.Live.Guard
  alias RavixWeb.Live.Panel
  alias RavixWeb.Live.Params
  alias RavixWeb.Markdown
  alias RavixWeb.ModelName

  @impl true
  def mount(_params, session, socket) do
    socket =
      assign(socket,
        track_id: session["track_id"],
        thread_id: session["track_id"],
        thread_generation: 0,
        threads: [],
        project_id: session["project_id"],
        track: nil,
        project: nil,
        header: nil,
        starters: [],
        page: Transcript.empty(""),
        # The markdown of every block on the page, rendered once per body.
        # See `memoize/1`.
        rendered: %{},
        loading: true,
        # The transcript is read separately from the rest of the track, and
        # is the slowest of the reads, so the page says which of the two it
        # is still waiting on rather than treating "loaded" as one moment.
        transcript_loading: true,
        queue: [],
        present: [],
        panel: Panel.new(),
        diff_path: nil,
        diff_filter: "",
        diff_show_large: false,
        preview: nil,
        preview_form: Form.new(:preview_config),
        preview_url: nil,
        dialog: nil,
        rename_form: Form.new(:rename_track),
        pull: nil,
        # The ribbon's three writes that are out --- `:interrupt`, `:retry`,
        # `:pull` --- each disabling the button that would repeat it. See
        # `begin/3`.
        pending: MapSet.new(),
        attached_images: [],
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
        track_guard: nil
      )

    if authorized?(socket) do
      socket =
        socket
        |> allow_upload(:images,
          accept: ~w(.png .jpg .jpeg .gif .webp),
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
        Process.send_after(self(), :refresh, @refresh_ms)
        announce(socket)
      end

      {:ok, if(connected?(socket), do: load(socket), else: socket)}
    else
      {:ok, redirect(socket, to: "/")}
    end
  end

  @impl true
  def handle_event("select-thread", %{"thread_id" => id}, socket) do
    case Access.thread_access(socket.assigns.current_user, socket.assigns.track_id, id) do
      # The selected tab is still a button; pressing it again keeps the
      # transcript and the follower it already has.
      {:ok, _} when id == socket.assigns.thread_id -> {:noreply, socket}
      {:ok, _} -> {:noreply, switch_thread(socket, id)}
      {:error, reason} -> {:noreply, error(socket, reason)}
    end
  end

  def handle_event("add-thread", _, socket) do
    if MapSet.member?(socket.assigns.pending, :add_thread),
      do: {:noreply, socket},
      else: {:noreply, begin(socket, :add_thread, &Tracks.add_thread/2)}
  end

  def handle_event("retry-load", _, socket), do: {:noreply, load(socket)}
  def handle_event("validate", _, socket), do: {:noreply, socket}

  def handle_event("typing", _, socket) do
    Tracks.beat(socket.assigns.current_user, socket.assigns.track_id, :typing)
    {:noreply, socket}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :images, ref)}

  def handle_event("clear-attachments", _, socket),
    do: {:noreply, assign(socket, attached_images: [])}

  def handle_event("send", %{"text" => text}, socket) do
    {complete, pending} = uploaded_entries(socket, :images)

    cond do
      pending != [] ->
        {:noreply, flash(socket, :error, "Wait for the images to finish uploading.")}

      length(complete) + length(socket.assigns.attached_images) > 6 ->
        {:noreply, flash(socket, :error, "Attach at most six images.")}

      upload_errors(socket.assigns.uploads.images) != [] ->
        {:noreply, flash(socket, :error, "Remove invalid images before sending.")}

      true ->
        send_prompt(socket, text)
    end
  end

  def handle_event("starter", %{"prompt" => prompt}, socket),
    do: {:noreply, push_event(socket, "composer:insert", %{text: prompt})}

  # Stopping and waking are Fountain round trips, and they used to be ones
  # this process waited out, like the file read below. The button is
  # disabled until the answer lands; see `begin/3`.
  def handle_event("interrupt", _, socket) do
    thread_id = socket.assigns.thread_id
    {:noreply, begin(socket, :interrupt, &Tracks.interrupt(&1, &2, thread_id))}
  end

  def handle_event("retry-track", _, socket),
    do: {:noreply, begin(socket, :retry, &Tracks.retry/2)}

  def handle_event("queue", %{"action" => "cancel", "id" => id}, socket),
    do: {:noreply, queued(socket, &PromptQueue.cancel/3, id)}

  def handle_event("queue", %{"action" => "retry", "id" => id}, socket),
    do: {:noreply, queued(socket, &PromptQueue.retry/3, id)}

  def handle_event("panel", %{"name" => name}, socket) when is_map_key(@tabs, name) do
    panel = Panel.select(socket.assigns.panel, Map.fetch!(@tabs, name))
    {:noreply, socket |> assign(panel: panel) |> load_panel()}
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

  def handle_event("refresh-panel", _, socket), do: {:noreply, load_panel(socket)}

  def handle_event("directory", %{"path" => path}, socket) do
    if Map.has_key?(socket.assigns.panel.directories, path) do
      {:noreply, update_panel(socket, &%{&1 | directories: Map.delete(&1.directories, path)})}
    else
      user = socket.assigns.current_user
      id = socket.assigns.track_id
      token = make_ref()

      {:noreply,
       socket
       |> update_panel(&%{&1 | directories: Map.put(&1.directories, path, {:loading, token})})
       |> traced_async({:directory, path, token}, fn -> Tracks.files(user, id, path) end)}
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
     |> traced_async(:file, fn -> Tracks.file(user, id, path) end)}
  end

  # One clause per button, because the four are four different calls: two of
  # them need the session hash to mint a ticket with and two have no use for
  # it. A single clause taking the word the button sent could only hand that
  # word onward and let the context sort it out, which is how "stop" and a
  # typo became the same request.
  def handle_event("preview", %{"action" => "open"}, socket),
    do: {:noreply, preview_async(socket, &Previews.open(&1, &2, &3))}

  def handle_event("preview", %{"action" => "restart"}, socket),
    do: {:noreply, preview_async(socket, &Previews.restart(&1, &2, &3))}

  def handle_event("preview", %{"action" => "stop"}, socket),
    do: {:noreply, preview_async(socket, fn user, id, _hash -> Previews.stop(user, id) end)}

  def handle_event("preview", %{"action" => "logs"}, socket),
    do: {:noreply, preview_async(socket, fn user, id, _hash -> Previews.logs(user, id) end)}

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

  def handle_event("close", params, socket) do
    {:noreply,
     result(
       socket,
       Tracks.close(socket.assigns.current_user, socket.assigns.track_id,
         force: Params.flag(params, "force")
       ),
       fn s, _ -> redirect(s, to: "/p/#{s.assigns.project_id}") end
     )}
  end

  # A GitHub round trip, off this process for the same reason as the two
  # above. The dialog stays open until GitHub answers, so a refusal lands in
  # front of the form that caused it.
  def handle_event("open-pull", params, socket) do
    attrs = Map.put(params, "draft", Params.flag(params, "draft", true))
    {:noreply, begin(socket, :pull, &Tracks.open_pull(&1, &2, attrs))}
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

  defp open_dialog(socket, dialog), do: assign(socket, dialog: dialog)

  @impl true
  # Ravix runs on more than one instance (ADR 0003) and a deploy is rolling,
  # so for one release a follower on an instance running the previous version
  # is still broadcasting Fountain's raw maps onto this topic. Normalising
  # here is the expand half of expand/contract: accept both shapes now, and
  # drop this clause once no instance publishes the old one.
  def handle_info({:select_thread, track_id, thread_id}, socket) do
    if track_id == socket.assigns.track_id and
         match?({:ok, _}, Access.thread_access(socket.assigns.current_user, track_id, thread_id)),
       do: {:noreply, switch_thread(socket, thread_id)},
       else: {:noreply, socket}
  end

  def handle_info({:transcript, id, %{} = raw}, socket) when not is_struct(raw),
    do: handle_info({:transcript, id, TranscriptEvent.from(raw)}, socket)

  def handle_info({:transcript, id, %TranscriptEvent{} = event}, socket) do
    if id == socket.assigns.thread_id,
      do: {:noreply, socket |> absorb(event) |> schedule_flush()},
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

  # A `live_component` cannot put a flash in the page's own socket, so it
  # sends the sentence here --- and this page has no toasts of its own
  # either, so `flash/3` sends it on up to the workspace, which draws the
  # one stack. See `RavixWeb.Live.Result.flash/3`.
  def handle_info({:flash, kind, message}, socket),
    do: {:noreply, flash(socket, kind, message)}

  def handle_info({:hub, %Event{} = event}, socket) do
    if Event.concerns?(event, socket.assigns.track_id) do
      {:noreply, hub(event, socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, socket |> refresh_detail() |> refresh_queue() |> refresh_transcript()}
  end

  # The follower went away, which on a cluster means its instance did (ADR
  # 0003): `:global` releases the name and starts no replacement, and this page
  # is the only thing that still knows which event id it holds. So it starts a
  # fresh follower from that id and re-reads the transcript to close whatever
  # the gap was. `follow/2` goes through `Tracks.follow/3`, so access is
  # re-established rather than assumed. A `:DOWN` for any other reference is a
  # monitor this page no longer owns.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    if socket.assigns.follower == ref do
      socket = assign(socket, follower: nil)

      {:noreply, socket |> follow(socket.assigns.page) |> refresh_transcript()}
    else
      {:noreply, socket}
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
  def handle_async(name, response, socket) do
    if authorized?(socket) do
      {:noreply, async_result(name, response, socket)}
    else
      {:noreply, redirect(socket, to: "/")}
    end
  end

  defp async_result(:add_thread, {:ok, {:ok, thread}}, socket) do
    socket = settle(socket, :add_thread)

    if thread.track_id == socket.assigns.track_id,
      do: switch_thread(socket, thread.id),
      else: socket
  end

  defp async_result(:add_thread, {:ok, {:error, reason}}, socket),
    do: socket |> settle(:add_thread) |> error(reason)

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
      threads: detail.threads,
      project: project,
      header: detail.header,
      starters: detail.starters,
      loading: false
    )
    # This render is the one that puts `#transcript-turns` on the page, and a
    # stream's pending inserts are consumed by whichever render comes next
    # whether or not that render contains the container. So a transcript that
    # answered first --- it is a separate read now, and it does sometimes win
    # --- has already had its turns dropped into a page that had no transcript
    # in it yet, and they are gone. Whatever `page` holds by now is written
    # again here, into the container that finally exists. When the transcript
    # is the one still outstanding this is an empty reset, and its own result
    # inserts into a container that is by then real.
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
    do: assign(socket, track: detail.track, header: detail.header, threads: detail.threads)

  defp async_result(:detail, {:ok, {:error, reason}}, socket), do: error(socket, reason)

  defp async_result(:queue, {:ok, {:ok, queue}}, socket), do: assign(socket, queue: queue)

  defp async_result(:queue, {:ok, {:error, reason}}, socket), do: error(socket, reason)

  # The same clause serves the read this page opens with and every repair
  # afterwards, because the difference between them is one question --- is
  # this page already following the track's live transcript? --- and the
  # answer is in `follower` rather than in which call asked. A page that is
  # not following subscribes from what it just read, which covers the first
  # read, a follower that went down between the `:DOWN` clause's own attempt
  # and now, and a track that had no conversation when it opened and has one
  # by the time the backstop tick comes round.
  defp async_result(:transcript, {:ok, {:ok, page}}, socket) do
    socket = if socket.assigns.follower, do: socket, else: follow(socket, page)

    # Sorted, because these come out of the turns newest-first within each
    # turn and the page they are about to be laid into grows cheaply only
    # while each event is newer than the one before it.
    newer =
      socket.assigns.page.turns
      |> Enum.flat_map(& &1.events)
      |> Enum.filter(&(&1.id > (page.last_event_id || 0)))
      |> Enum.sort_by(& &1.id)

    socket
    |> assign(transcript_loading: false)
    |> repair(Transcript.add_events(page, newer))
  end

  defp async_result(:transcript, {:ok, {:error, reason}}, socket),
    do: socket |> assign(transcript_loading: false) |> error(reason)

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

      update_panel(socket, &%{&1 | directories: Map.put(&1.directories, path, value)})
    else
      socket
    end
  end

  defp async_result(:panel, {:ok, {:ok, %Previews.View{} = preview}}, socket),
    do: socket |> show_preview(preview) |> update_panel(&Panel.settled/1)

  defp async_result(:panel, {:ok, {:ok, data}}, socket),
    do: update_panel(socket, &Panel.loaded(&1, data))

  defp async_result(:panel, {:ok, {:error, reason}}, socket),
    do: update_panel(socket, &Panel.failed(&1, Error.from(reason).message))

  defp async_result(:preview_action, {:ok, response}, socket) do
    result(update_panel(socket, &Panel.settled/1), response, fn s, preview ->
      s
      |> show_preview(preview)
      |> assign(preview_url: preview.open_url || s.assigns.preview_url)
    end)
  end

  defp async_result(:interrupt, {:ok, response}, socket),
    do: result(settle(socket, :interrupt), response, fn s, _ -> refresh_detail(s) end)

  defp async_result(:retry, {:ok, response}, socket),
    do: result(settle(socket, :retry), response, fn s, _ -> load(s) end)

  defp async_result(:pull, {:ok, response}, socket),
    do: result(settle(socket, :pull), response, &assign(&1, pull: &2, dialog: nil))

  # One of the ribbon's writes that did not answer. Not the loading clause
  # below: nothing was being loaded, and "could not finish loading" about a
  # Stop that crashed would be a sentence about the wrong thing.
  defp async_result(name, {:exit, reason}, socket)
       when name in [:interrupt, :retry, :pull, :add_thread],
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
    socket = memoize(assign(socket, page: page))

    if appended_to?(was, now),
      do: Enum.reduce(now, socket, &insert_changed(&2, was, &1)),
      else: stream(socket, :turns, now, reset: true)
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

  # File paths are issued by LiveView after validating its managed upload.
  # sobelow_skip ["Traversal.FileModule"]
  defp send_prompt(socket, text) do
    images =
      consume_uploaded_entries(socket, :images, fn %{path: path}, entry ->
        {:ok, %{data: Base.encode64(File.read!(path)), media_type: entry.client_type}}
      end)

    images = socket.assigns.attached_images ++ images
    socket = assign(socket, attached_images: images)

    response =
      Tracks.prompt(socket.assigns.current_user, socket.assigns.track_id, %{
        thread_id: socket.assigns.thread_id,
        prompt: text,
        images: images,
        request_id: Ecto.UUID.generate()
      })

    {:noreply,
     result(socket, response, fn s, _ ->
       Tracks.mark_read(s.assigns.current_user, s.assigns.track_id, s.assigns.thread_id)
       s |> assign(attached_images: []) |> push_event("composer:clear", %{}) |> refresh_queue()
     end)}
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
    |> unfollow()
    |> drop_attachments()
    |> update(:thread_generation, &(&1 + 1))
    |> assign(thread_id: id)
    |> load()
  end

  defp arrive(socket, project, track) do
    if project.id != socket.assigns.project_id do
      Hub.unsubscribe(socket.assigns.project_id)
      Hub.subscribe(project.id)
    end

    socket
    |> unfollow()
    |> drop_pending()
    |> drop_attachments()
    |> assign(
      track_id: track.id,
      thread_id: track.id,
      thread_generation: socket.assigns.thread_generation + 1,
      threads: [],
      project_id: project.id,
      track: track,
      project: project,
      header: nil,
      starters: [],
      queue: [],
      present: [],
      panel: Panel.new(),
      diff_path: nil,
      diff_filter: "",
      diff_show_large: false,
      preview: nil,
      preview_form: Form.new(:preview_config),
      preview_url: nil,
      dialog: nil,
      rename_form: Form.new(:rename_track),
      pull: nil
    )
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
      transcript_loading: true,
      page: Transcript.empty(""),
      rendered: %{}
    )
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
    |> load_panel()
  end

  # Read the event now, draw it in a moment. See `@flush_ms`.
  #
  # Which turns moved is remembered rather than which events arrived, because
  # that is what the drawing needs and a burst of two hundred frames usually
  # names one turn. A stage event is remembered as a flag for the same reason:
  # a turn that starts, runs and ends inside one window is three reasons to
  # re-read the track and one re-read.
  defp absorb(socket, event) do
    assign(socket,
      page: Transcript.add_event(socket.assigns.page, event),
      dirty_turns: MapSet.put(socket.assigns.dirty_turns, event.turn_id),
      stage_seen?: socket.assigns.stage_seen? or event.kind == :stage,
      announcement: announce_turn(event, socket.assigns.announcement)
    )
  end

  # The sentence for the live region, if this event is worth one. A turn
  # ending is; a turn starting clears the last one, so that two replies in a
  # row are two changes to the region and not one sentence left standing,
  # which a screen reader would read once. Everything else --- every token
  # of output --- leaves it alone.
  defp announce_turn(%TranscriptEvent{} = event, current) do
    cond do
      TranscriptEvent.starts_turn?(event) -> nil
      not TranscriptEvent.settles?(event) -> current
      TranscriptEvent.failed_stage?(event) -> "Turn failed"
      true -> "Agent replied"
    end
  end

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

      socket |> refresh_detail() |> refresh_queue() |> refresh_transcript()
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

  # The four preview buttons all do the same thing to the page -- mark the
  # panel busy and answer later -- and differ only in which context call they
  # make, so that call is what they pass in.
  defp preview_async(socket, call) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    hash = socket.assigns.session_hash

    socket
    |> update_panel(&%{&1 | busy?: true})
    |> traced_async(:preview_action, fn -> call.(user, id, hash) end)
  end

  attr :threads, :list, required: true
  attr :thread_id, :string, required: true
  attr :adding, :boolean, default: false
  attr :enabled, :boolean, required: true

  @doc """
  The track's threads as a row of tabs above the composer, with "+" at the
  end when threads can be added. A track with one thread that cannot gain
  another has nothing to switch between, so the row is not drawn at all.

  Plain buttons in a labelled nav: each is reachable with Tab and fires on
  Enter or Space, the selected one carries `aria-current`, and an unread
  thread's dot has a spoken label.
  """
  def thread_tabs(assigns) do
    ~H"""
    <nav
      :if={length(@threads) > 1 or @enabled}
      id="thread-switcher"
      class="thread-tabs"
      aria-label="Threads"
    >
      <button
        :for={thread <- @threads}
        type="button"
        class="thread-tab"
        phx-click="select-thread"
        phx-value-thread_id={thread.id}
        data-thread-id={thread.id}
        aria-current={if thread.id == @thread_id, do: "true"}
        title={thread.title}
      >
        <span class="thread-tab-title">{thread.title}</span><span
          :if={thread.unread && thread.id != @thread_id}
          class="thread-unread"
        ><span class="sr-only">(unread)</span></span>
      </button>
      <button
        :if={@enabled}
        type="button"
        class="ghost thread-add"
        aria-label="Add thread"
        title="Add thread"
        phx-click="add-thread"
        disabled={@adding}
      >
        <.icon name="plus" size={14} />
      </button>
    </nav>
    """
  end

  attr :directories, :map, default: %{}
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
      <.file_listing listing={@data} directories={@directories} file={@file} />
      <div :if={@file}>
        <h4>{@file.path}</h4>
        <pre :if={@file.encoding != "base64"}>{@file.content}</pre>
        <p :if={@file.encoding == "base64"}>Binary file ({@file.size} bytes).</p>
        <p :if={@file.truncated}>File content is truncated.</p>
      </div>
    </div>
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
      <p :if={@data.diff == ""}>No changes yet.</p>
      <p>
        {length(@data.changes)} changed files <span class="diff-add">+{@added}</span>
        <span class="diff-del">−{@removed}</span>
      </p>
      <p :if={@data.truncated}>Diff is truncated.</p>
      <div :if={!@selected}>
        <form id="diff-filter-form" phx-change="filter-diff" phx-submit="filter-diff">
          <label for="diff-filter">Filter paths</label>
          <input id="diff-filter" name="filter" type="search" value={@diff_filter} phx-debounce="150" />
        </form>
        <p :if={@filtered == [] and @data.diff != ""}>No matching files.</p>
        <button
          :for={file <- @filtered}
          type="button"
          class="change-file"
          phx-click="select-diff"
          phx-value-path={file.change.path}
        >
          <span class="change-status">{diff_status(file.change.status)}</span>
          <span class="change-path"><span :if={file.change.status == :renamed}>{file.old_path} → </span><span class="change-directory">{diff_directory(
            file.change.path
          )}</span><strong>{Path.basename(file.change.path)}</strong></span>
          <span class="change-counts"><span class="diff-add">+{file.change.added}</span>
          <span class="diff-del">−{file.change.removed}</span></span>
          <span :if={file.partial}>Partial</span>
        </button>
      </div>
      <div :if={@selected}>
        <button type="button" phx-click="close-diff">← All changed files</button>
        <h4 class="change-path">
          <span :if={@selected.change.status == :renamed}>{@selected.old_path} → </span>{@selected.change.path}
        </h4>
        <p :if={@selected.partial}>Partial file — diff was truncated.</p>
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

  defp panel_body(%{data: %ChecksReport{}} = assigns) do
    ~H"""
    <div>
      <p :if={@data.pull}>
        <a href={@data.pull.url} target="_blank" rel="noreferrer">
          Pull request #{@data.pull.number}: {@data.pull.title}
        </a>
      </p>
      <div :for={check <- @data.runs}>
        <a :if={check.url} href={check.url} target="_blank" rel="noreferrer">
          {check.name}
        </a>
        <span :if={!check.url}>{check.name}</span>
        <span class="chip">{check.conclusion || check.status}</span>
      </div>
      <button
        :if={@project.repo}
        class="primary"
        phx-click={JS.push_focus() |> JS.push("dialog")}
        phx-value-name="pull"
      >
        Open pull request
      </button>
    </div>
    """
  end

  defp diff_status(status), do: %{added: "A", modified: "M", deleted: "D", renamed: "R"}[status]
  defp diff_marker(kind), do: %{add: "+", del: "−", context: " "}[kind]

  defp diff_line_label(%{kind: :add, new: new}), do: "Added line #{new}: "
  defp diff_line_label(%{kind: :del, old: old}), do: "Removed line #{old}: "
  defp diff_line_label(%{new: new}), do: "Line #{new}: "

  attr :listing, :any, required: true
  attr :directories, :map, required: true
  attr :file, :any, required: true

  defp file_listing(assigns) do
    assigns =
      assign(
        assigns,
        :entries,
        Enum.sort_by(assigns.listing.entries, &{&1.type != "directory", String.downcase(&1.name)})
      )

    ~H"""
    <ul class="file-list">
      <li :for={entry <- @entries}>
        <% path = Path.join(@listing.path, entry.name) %>
        <% child = @directories[path] %>
        <button
          type="button"
          class={["workspace-file", @file && @file.path == path && "selected"]}
          phx-click={if entry.type == "directory", do: "directory", else: "file"}
          phx-value-path={path}
          aria-expanded={if entry.type == "directory", do: to_string(child != nil)}
          aria-current={if @file && @file.path == path, do: "true"}
          title={path}
        >
          <span class="file-disclosure"><.icon
            :if={entry.type == "directory"}
            name="chevron"
            open={child != nil}
            size={12}
          /></span>
          <.icon name={file_icon(entry)} class="file-kind" />
          <span class="file-name">{entry.name}</span>
        </button>
        <.file_listing
          :if={is_struct(child, Files.Listing)}
          listing={child}
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

  defp file_icon(%{type: "directory"}), do: "folder"

  defp file_icon(entry) do
    case String.downcase(Path.extname(entry.name)) do
      ext when ext in ~w(.ex .exs .js .jsx .ts .tsx .py .rb .rs .go .html .css .sh) -> "code"
      ext when ext in ~w(.png .jpg .jpeg .gif .svg .webp .ico) -> "picture"
      ext when ext in ~w(.json .yaml .yml .toml .ini .lock .config) -> "settings"
      ext when ext in ~w(.md .txt .rst .pdf) -> "document"
      _ -> "file"
    end
  end

  defp diff_directory(path),
    do: if(Path.dirname(path) == ".", do: "", else: Path.dirname(path) <> "/")

  defp large_diff?(file),
    do:
      Enum.reduce(file.hunks, 0, &(length(&1.lines) + &2)) > 1000 or
        Enum.any?(file.hunks, fn hunk -> Enum.any?(hunk.lines, &(byte_size(&1.text) > 20_000)) end)

  defp load_panel(socket, path \\ nil) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    tab = socket.assigns.panel.tab

    socket
    |> update_panel(&Panel.loading/1)
    |> traced_async(:panel, fn ->
      case tab do
        :files -> Tracks.files(user, id, path)
        :changes -> Tracks.diff(user, id)
        :checks -> Tracks.checks(user, id)
        :preview -> Previews.status(user, id)
      end
    end)
  end

  defp update_panel(socket, fun), do: assign(socket, panel: fun.(socket.assigns.panel))

  defp queued(socket, call, id) do
    response = call.(socket.assigns.current_user, socket.assigns.track_id, id)
    result(socket, response, fn s, _ -> refresh_queue(s) end)
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

  defp hub(%Event{name: :turn}, socket),
    do: socket |> refresh_detail() |> refresh_queue() |> refresh_transcript()

  defp hub(%Event{name: name}, socket) when name in [:people, :tracks, :settings],
    do: refresh_detail(socket)

  # Somebody's read mark moved. This page is the one that moves it, and it
  # draws nothing from it: the unread dot is the rail's, and the rail clears
  # its own. Not a reason to re-read the detail, which is two Fountain round
  # trips, on every load, stage and send of every other page on this track.
  defp hub(%Event{name: :read}, socket), do: socket

  # The configuration form always shows what would actually be used --- the
  # track's override if it has one, the project's default otherwise --- so
  # it is rebuilt whenever the preview is, rather than being a box somebody
  # typed in once. Rebuilding also clears a refusal from the last attempt.
  defp show_preview(socket, %Previews.View{} = preview) do
    config = preview.config || %{}

    assign(socket,
      preview: preview,
      preview_form:
        Form.new(:preview_config, %{
          "directory" => Map.get(config, :directory, "."),
          "command" => Map.get(config, :command, ""),
          "readiness_path" => Map.get(config, :readiness_path, "/")
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
  defp refresh_detail(%{assigns: %{track: nil}} = socket), do: socket

  defp refresh_detail(socket) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    thread_id = socket.assigns.thread_id

    generation = socket.assigns.thread_generation

    traced_async(socket, {:detail, thread_id, generation}, fn ->
      Tracks.get(user, id, fresh: true, thread_id: thread_id)
    end)
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
    do: track.role == :owner or track.created_by_login == user.login

  defp hide_track_actions(js \\ %JS{}) do
    js
    |> JS.set_attribute({"hidden", ""}, to: "#track-actions-menu")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#track-actions-toggle")
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
  defp folds?(_block), do: true

  attr :blocks, :list, required: true
  attr :rendered, :map, required: true

  # `open` is the reader's: the server never sets it, and ignoring it keeps a
  # patch to a live turn from closing the fold somebody just opened.
  defp work(assigns) do
    tools = for %TranscriptBlock.Tool{} = tool <- assigns.blocks, do: tool

    assigns =
      assign(assigns,
        label: work_label(assigns.blocks, length(tools)),
        failed: Enum.count(tools, &(&1.status == :error)),
        now: tools |> Enum.reverse() |> Enum.find(&(&1.status == :running))
      )

    ~H"""
    <details class="workspace-work" phx-mounted={JS.ignore_attributes("open")}>
      <summary>
        <span>{@label}</span>
        <span :if={@failed > 0} class="chip tool-error">{@failed} failed</span>
        <span :if={@now} class="work-now">{@now.name}</span>
      </summary>
      <div class="workspace-work-body">
        <div :for={block <- @blocks}>
          <.block block={block} html={rendered(@rendered, block)} />
        </div>
      </div>
    </details>
    """
  end

  defp work_label(blocks, tools) do
    [
      counted(tools, "tool call"),
      counted(Enum.count(blocks, &match?(%TranscriptBlock.Text{}, &1)), "message"),
      counted(Enum.count(blocks, &match?(%TranscriptBlock.Thinking{}, &1)), "thought")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp counted(0, _noun), do: nil
  defp counted(1, noun), do: "1 #{noun}"
  defp counted(n, noun), do: "#{n} #{noun}s"

  attr :turn, :map, required: true
  attr :workdir, :string, default: nil

  # What a finished turn cost and left behind: how long it ran, when it
  # ended, the answer to copy, and the files its edits touched. The time is
  # written in UTC and rewritten in the reader's own zone by
  # `assets/js/hooks/transcript_tail.js`, since the server does not know it.
  defp turn_footer(assigns) do
    %{turn: turn, workdir: workdir} = assigns
    {started, ended} = turn_span(turn.events)
    files = changed_files(turn.blocks, workdir)
    {shown, rest} = Enum.split(files, 2)

    assigns =
      assign(assigns,
        duration: started && ended && duration(DateTime.diff(ended, started)),
        ended: ended,
        answer: answer(turn.blocks),
        shown: shown,
        rest: rest
      )

    ~H"""
    <footer class="turn-footer">
      <span :if={@duration}>{@duration}</span>
      <span :if={@duration && @ended} aria-hidden="true">·</span>
      <time :if={@ended} datetime={DateTime.to_iso8601(@ended)} data-local-time>
        {Calendar.strftime(@ended, "%H:%M")} UTC
      </time>
      <button
        :if={@answer != ""}
        type="button"
        class="ghost turn-copy"
        aria-label="Copy answer"
        title="Copy answer"
        data-copy={@answer}
      >
        <.icon name="copy" size={13} />
      </button>
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
    </footer>
    """
  end

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

  # What a call was run on, when its name does not already say so. An
  # adapter commonly titles a shell call with the command itself, and the
  # summary the ACP library builds is every argument as `key=value`, so the
  # row used to read the command twice and then the working directory. The
  # arguments are all in the expanded body; the row names one of them.
  @primary_inputs ~w(command cmd file_path path pattern query url)

  defp tool_summary(%TranscriptBlock.Tool{name: name, detail: detail}) do
    candidate =
      List.first(detail.paths) ||
        Enum.find_value(@primary_inputs, fn key ->
          case detail.input[key] do
            value when is_binary(value) and value != "" -> value
            _ -> nil
          end
        end)

    if candidate && !names?(name || "", candidate), do: candidate
  end

  # A title may be the command cut short with an ellipsis.
  defp names?(name, candidate) do
    stem = name |> String.trim_trailing("…") |> String.trim_trailing("...")
    String.contains?(name, candidate) or (stem != "" and String.starts_with?(candidate, stem))
  end

  # One head per block struct, rather than five `:if` comparisons against a
  # `:kind` field the blocks no longer carry. A block shape added to
  # `Ravix.Tracks.Transcript.Block` and not drawn here is a
  # `FunctionClauseError` on the page that would have rendered it silently
  # blank, which is the trade this conversion was for.
  attr :block, :map, required: true
  attr :html, :any, default: nil, doc: "this body's markdown, if `memoize/1` has it"

  defp block(%{block: %TranscriptBlock.Text{}} = assigns) do
    ~H"""
    <div class="md">{@html || Markdown.render_safe(@block.body)}</div>
    """
  end

  defp block(%{block: %TranscriptBlock.Thinking{}} = assigns) do
    ~H"""
    <details class="workspace-thinking">
      <summary>Thinking</summary>
      <div class="md">{@html || Markdown.render_safe(@block.body)}</div>
    </details>
    """
  end

  defp block(%{block: %TranscriptBlock.Raw{}} = assigns) do
    ~H"""
    <pre>{@block.body}</pre>
    """
  end

  defp block(%{block: %TranscriptBlock.Failure{}} = assigns) do
    ~H"""
    <div class="workspace-failure" role="status">
      <strong>{@block.stage} failed</strong>
      <pre :if={@block.body != ""}>{@block.body}</pre>
    </div>
    """
  end

  defp block(%{block: %TranscriptBlock.Tool{}} = assigns) do
    assigns = assign(assigns, :summary, tool_summary(assigns.block))

    ~H"""
    <details class="workspace-tool">
      <summary>
        <span :if={@block.status != :done} class={"chip tool-#{@block.status}"}>{@block.status}</span>
        {@block.name}
        <span :if={@summary} class="tool-summary">{@summary}</span>
      </summary>
      <pre :if={@block.detail.input != %{}}>{Jason.encode!(@block.detail.input, pretty: true)}</pre>
      <p :for={path <- @block.detail.paths}><code>{path}</code></p>
      <div :for={edit <- @block.detail.edits}>
        <strong>{edit.path}</strong><pre><span :for={line <- edit.lines} class={"diff-#{line.kind}"}>{line.text}{"\n"}</span></pre>
      </div>
      <pre :if={@block.output != ""}>{@block.output}</pre>
    </details>
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

  defp prompt_message(assigns) do
    prompt = Ravix.Previews.Agent.visible_prompt(assigns.prompt)
    {speaker, body} = prompt_author(prompt)
    assigns = assign(assigns, speaker: speaker, body: body)

    ~H"""
    <div class="said">
      <span class="speaker">{@speaker}</span>
      <div class="workspace-prompt">{@body}</div>
    </div>
    """
  end

  # Shared prompts carry PromptQueue.with_author/2's marker after the preview
  # instructions. Never infer an old, untagged message's author from its viewer.
  defp prompt_author(prompt) do
    case Regex.run(~r/\A\[from @([a-zA-Z0-9-]+)\] (.*)\z/s, prompt) do
      [_, login, body] -> {"@" <> login, body}
      nil -> app_or_unattributed_prompt(prompt)
    end
  end

  defp app_or_unattributed_prompt(prompt) do
    case Transcript.app_turn_label(prompt) do
      nil -> {"User", prompt}
      label -> {"Ravix", label}
    end
  end

  defp upload_error(:too_large), do: "Image is larger than 8 MB."
  defp upload_error(:too_many_files), do: "Attach at most six images."
  defp upload_error(_), do: "Use a PNG, JPEG, GIF, or WebP image."
end
