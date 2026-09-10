defmodule RavixWeb.TrackLive do
  @moduledoc "One track's transcript, composer, sharing, and machine panels."
  use RavixWeb, :live_view
  on_mount {RavixWeb.Live.Hooks, :require_authenticated_user}

  alias Ravix.{Accounts, Crypto, Hub, People, Previews, PromptQueue, Terminal, Tracks, Vitals}
  alias Ravix.Accounts.Access
  alias Ravix.Hub.Event
  alias Ravix.Tracks.Transcript
  alias RavixWeb.Error

  @impl true
  def mount(_params, session, socket) do
    socket =
      assign(socket,
        track_id: session["track_id"],
        project_id: session["project_id"],
        session_hash: Crypto.sha256(session["session_token"]),
        track: nil,
        project: nil,
        header: nil,
        starters: [],
        page: Transcript.empty(""),
        loading: true,
        queue: [],
        present: [],
        panel: "files",
        panel_data: nil,
        panel_error: nil,
        panel_busy: false,
        file: nil,
        dock: "terminal",
        dock_open: false,
        output: [],
        exec_busy: false,
        cwd: nil,
        preview: nil,
        preview_url: nil,
        dialog: nil,
        people: [],
        invite: nil,
        pull: nil,
        attached_images: [],
        vitals: nil,
        # The monitor reference for this page's transcript follower, if it has
        # one. See `follow/2`.
        follower: nil
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
        |> attach_hook(:track_event_access, :handle_event, fn _, _, s -> guard(s) end)
        |> attach_hook(:track_message_access, :handle_info, fn _, s -> guard(s) end)
        |> attach_hook(:track_async_access, :handle_async, fn _, _, s -> guard(s) end)

      if connected?(socket) do
        Hub.subscribe(socket.assigns.project_id)
        Process.send_after(self(), :refresh, 15_000)
      end

      {:ok, if(connected?(socket), do: load(socket), else: socket)}
    else
      {:ok, redirect(socket, to: "/")}
    end
  end

  @impl true
  def handle_event("retry-load", _, socket), do: {:noreply, load(socket)}
  def handle_event("validate", _, socket), do: {:noreply, socket}

  def handle_event("typing", _, socket) do
    Tracks.beat(socket.assigns.current_user, socket.assigns.track_id, true)
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
        {:noreply, put_flash(socket, :error, "Wait for the images to finish uploading.")}

      length(complete) + length(socket.assigns.attached_images) > 6 ->
        {:noreply, put_flash(socket, :error, "Attach at most six images.")}

      upload_errors(socket.assigns.uploads.images) != [] ->
        {:noreply, put_flash(socket, :error, "Remove invalid images before sending.")}

      true ->
        send_prompt(socket, text)
    end
  end

  def handle_event("starter", %{"prompt" => prompt}, socket),
    do: {:noreply, push_event(socket, "composer:insert", %{text: prompt})}

  def handle_event("interrupt", _, socket),
    do:
      {:noreply,
       result(
         socket,
         Tracks.interrupt(socket.assigns.current_user, socket.assigns.track_id),
         fn s, _ -> refresh_detail(s) end
       )}

  def handle_event("retry-track", _, socket),
    do:
      {:noreply,
       result(socket, Tracks.retry(socket.assigns.current_user, socket.assigns.track_id), fn s,
                                                                                             _ ->
         load(s)
       end)}

  def handle_event("queue", %{"action" => action, "id" => id}, socket)
      when action in ~w(cancel retry) do
    response =
      if action == "cancel",
        do: PromptQueue.cancel(socket.assigns.current_user, socket.assigns.track_id, id),
        else: PromptQueue.retry(socket.assigns.current_user, socket.assigns.track_id, id)

    {:noreply, result(socket, response, fn s, _ -> refresh_queue(s) end)}
  end

  def handle_event("panel", %{"name" => name}, socket)
      when name in ~w(files changes checks preview) do
    {:noreply, socket |> assign(panel: name, file: nil) |> load_panel()}
  end

  def handle_event("refresh-panel", _, socket), do: {:noreply, load_panel(socket)}

  def handle_event("directory", %{"path" => path}, socket),
    do: {:noreply, load_panel(assign(socket, file: nil), path)}

  def handle_event("file", %{"path" => path}, socket) do
    {:noreply,
     result(
       socket,
       Tracks.file(socket.assigns.current_user, socket.assigns.track_id, path),
       &assign(&1, file: &2)
     )}
  end

  def handle_event("dock", %{"name" => name}, socket) when name in ~w(terminal run vitals) do
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
      {:noreply, socket}
    else
      user = socket.assigns.current_user
      id = socket.assigns.track_id
      cwd = socket.assigns.cwd

      socket =
        assign(socket,
          exec_busy: true,
          output:
            Enum.take(
              socket.assigns.output ++ [%{command: command, stdout: "", stderr: "", code: nil}],
              -200
            )
        )

      {:noreply,
       start_async(socket, :exec, fn -> Terminal.exec(user, id, %{command: command, cwd: cwd}) end)}
    end
  end

  def handle_event("clear", _, socket), do: {:noreply, assign(socket, output: [])}

  def handle_event("preview", %{"action" => action}, socket)
      when action in ~w(open restart stop logs) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    hash = socket.assigns.session_hash

    {:noreply,
     socket
     |> assign(panel_busy: true)
     |> start_async(:preview_action, fn ->
       Previews.act(user, id, action, %{session_hash: hash})
     end)}
  end

  def handle_event("preview-config", params, socket) do
    config =
      if params["clear"] == "true",
        do: nil,
        else: Map.take(params, ~w(directory command readiness_path))

    {:noreply,
     result(
       socket,
       Previews.act(socket.assigns.current_user, socket.assigns.track_id, "config", %{
         config: config
       }),
       &assign(&1, preview: &2)
     )}
  end

  def handle_event("dialog", %{"name" => name}, socket)
      when name in ~w(rename close people pull) do
    socket = assign(socket, dialog: name)

    {:noreply,
     if(name == "people",
       do:
         result(
           socket,
           People.list(socket.assigns.current_user, socket.assigns.track_id),
           &assign(&1, people: &2)
         ),
       else: socket
     )}
  end

  def handle_event("dismiss", _, socket), do: {:noreply, assign(socket, dialog: nil)}

  def handle_event("rename", %{"title" => title}, socket) do
    {:noreply,
     result(
       socket,
       Tracks.rename(socket.assigns.current_user, socket.assigns.track_id, title),
       fn s, _ -> s |> assign(dialog: nil) |> refresh_detail() end
     )}
  end

  def handle_event("close", params, socket) do
    {:noreply,
     result(
       socket,
       Tracks.close(socket.assigns.current_user, socket.assigns.track_id,
         force: params["force"] == "true"
       ),
       fn s, _ -> redirect(s, to: "/p/#{s.assigns.project_id}") end
     )}
  end

  def handle_event("invite-person", %{"login" => login}, socket) do
    {:noreply,
     result(
       socket,
       People.add(socket.assigns.current_user, socket.assigns.track_id, login),
       &assign(&1, people: &2)
     )}
  end

  def handle_event("remove-person", %{"login" => login}, socket) do
    {:noreply,
     result(
       socket,
       People.remove(socket.assigns.current_user, socket.assigns.track_id, login),
       fn s, _ ->
         if login == s.assigns.current_user.login,
           do: redirect(s, to: "/"),
           else:
             result(
               s,
               People.list(s.assigns.current_user, s.assigns.track_id),
               &assign(&1, people: &2)
             )
       end
     )}
  end

  def handle_event("invite-link", %{"action" => action}, socket) do
    response =
      if action == "create",
        do: People.mint_link(socket.assigns.current_user, socket.assigns.track_id),
        else: People.drop_link(socket.assigns.current_user, socket.assigns.track_id)

    {:noreply,
     result(socket, response, fn s, v ->
       assign(s, invite: if(action == "create", do: v, else: nil))
     end)}
  end

  def handle_event("open-pull", params, socket) do
    attrs = Map.put(params, "draft", params["draft"] != "false")

    {:noreply,
     result(
       socket,
       Tracks.open_pull(socket.assigns.current_user, socket.assigns.track_id, attrs),
       &assign(&1, pull: &2, dialog: nil)
     )}
  end

  @impl true
  def handle_info({:transcript, id, event}, socket) do
    if id == socket.assigns.track_id do
      page = Transcript.add_event(socket.assigns.page, event)
      socket = assign(socket, page: page)
      turn_id = event["turn_id"] || "pending"

      socket =
        case Enum.find(page.turns, &(&1.id == turn_id)) do
          %{visible?: true} = turn -> stream_insert(socket, :turns, turn)
          _ -> socket
        end

      if event["kind"] == "stage" do
        Tracks.mark_read(socket.assigns.current_user, id)
        {:noreply, socket |> refresh_detail() |> refresh_queue() |> refresh_transcript()}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # An event about a *sibling* track is not this page's business, and saying
  # so is most of what typing the hub bought. A project with several tracks
  # being worked on publishes constantly -- a turn starting, a queue moving,
  # somebody reading a transcript -- and every one of those used to cost
  # every open page a re-read of its own track, its queue and its whole
  # transcript. An event naming no track at all is the project's, and is
  # never skipped.
  def handle_info({:hub, %Event{} = event}, socket) do
    if Event.concerns?(event, socket.assigns.track_id) do
      {:noreply, hub(event, socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 15_000)
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
  def handle_async(name, response, socket) do
    if authorized?(socket) do
      {:noreply, async_result(name, response, socket)}
    else
      {:noreply, redirect(socket, to: "/")}
    end
  end

  defp async_result(:load, {:ok, {:ok, detail, project, page}}, socket) do
    socket = if detail.track.conversation_id, do: follow(socket, page), else: socket

    Tracks.beat(socket.assigns.current_user, socket.assigns.track_id, false)
    Tracks.mark_read(socket.assigns.current_user, socket.assigns.track_id)

    socket
    |> assign(
      track: detail.track,
      project: project,
      header: detail.header,
      starters: detail.starters,
      page: page,
      loading: false,
      cwd: detail.track.workdir
    )
    |> stream(:turns, Transcript.visible_turns(page), reset: true)
    |> refresh_queue()
    |> load_panel()
  end

  defp async_result(:load, {:ok, {:error, reason}}, socket),
    do: socket |> assign(loading: false) |> error(reason)

  defp async_result(:transcript, {:ok, {:ok, page}}, socket) do
    newer =
      socket.assigns.page.turns
      |> Enum.flat_map(& &1.events)
      |> Enum.filter(&(&1["id"] > (page.last_event_id || 0)))

    page = Transcript.add_events(page, newer)
    socket |> assign(page: page) |> stream(:turns, Transcript.visible_turns(page), reset: true)
  end

  defp async_result(:transcript, {:ok, {:error, reason}}, socket), do: error(socket, reason)

  defp async_result(:panel, {:ok, {:ok, data}}, socket) do
    if socket.assigns.panel == "preview",
      do: assign(socket, preview: data, panel_busy: false),
      else: assign(socket, panel_data: data, panel_busy: false)
  end

  defp async_result(:panel, {:ok, {:error, reason}}, socket),
    do: assign(socket, panel_busy: false, panel_error: Error.from(reason).message)

  defp async_result(:exec, {:ok, response}, socket) do
    result(assign(socket, exec_busy: false), response, fn s, output ->
      assign(s,
        cwd: output.cwd,
        output: List.update_at(s.assigns.output, -1, &Map.merge(&1, output))
      )
    end)
  end

  defp async_result(:preview_action, {:ok, response}, socket) do
    result(assign(socket, panel_busy: false), response, fn s, preview ->
      assign(s, preview: preview, preview_url: preview[:open_url] || s.assigns.preview_url)
    end)
  end

  defp async_result(_name, {:exit, _reason}, socket),
    do:
      socket
      |> assign(loading: false, panel_busy: false, exec_busy: false)
      |> put_flash(:error, "Could not finish loading. Please try again.")

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
        prompt: text,
        images: images,
        request_id: Ecto.UUID.generate()
      })

    {:noreply,
     result(socket, response, fn s, _ ->
       Tracks.mark_read(s.assigns.current_user, s.assigns.track_id)
       s |> assign(attached_images: []) |> push_event("composer:clear", %{}) |> refresh_queue()
     end)}
  end

  defp load(socket) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    project_id = socket.assigns.project_id

    socket
    |> assign(loading: true)
    |> start_async(:load, fn ->
      with {:ok, detail} <- Tracks.get(user, id),
           {:ok, project} <- Ravix.Projects.get(user, project_id),
           {:ok, page} <- Tracks.events(user, id),
           do: {:ok, detail, project, page}
    end)
  end

  # Subscribe to the track's live transcript from the newest event this page
  # already has, and monitor the follower that serves it. The monitor is the
  # whole point: see the `:DOWN` clause above. The page's own transcript is
  # unaffected by a failure here, which is why an error is not surfaced -- the
  # events simply stop arriving and the fifteen-second refresh keeps working.
  defp follow(socket, page) do
    case socket.assigns.follower do
      nil -> :ok
      ref -> Process.demonitor(ref, [:flush])
    end

    case Tracks.follow(socket.assigns.current_user, socket.assigns.track_id,
           after: page.last_event_id
         ) do
      {:ok, pid} -> assign(socket, follower: Process.monitor(pid))
      {:error, _reason} -> assign(socket, follower: nil)
    end
  end

  defp refresh_transcript(socket) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    start_async(socket, :transcript, fn -> Tracks.events(user, id) end)
  end

  defp load_panel(socket, path \\ nil) do
    user = socket.assigns.current_user
    id = socket.assigns.track_id
    panel = socket.assigns.panel

    socket
    |> assign(panel_busy: true, panel_error: nil, panel_data: nil)
    |> start_async(:panel, fn ->
      case panel do
        "files" -> Tracks.files(user, id, path)
        "changes" -> Tracks.diff(user, id)
        "checks" -> Tracks.checks(user, id)
        "preview" -> Previews.status(user, id)
      end
    end)
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

  defp refresh_detail(%{assigns: %{track: nil}} = socket), do: socket

  defp refresh_detail(socket) do
    result(socket, Tracks.get(socket.assigns.current_user, socket.assigns.track_id), fn s,
                                                                                        detail ->
      assign(s, track: detail.track, header: detail.header)
    end)
  end

  defp refresh_queue(socket),
    do:
      result(
        socket,
        PromptQueue.list(socket.assigns.current_user, socket.assigns.track_id),
        &assign(&1, queue: &2)
      )

  defp authorized?(socket) do
    case Access.track_access(socket.assigns.current_user, socket.assigns.track_id) do
      {:ok, %{track: track}} ->
        track.project_id == socket.assigns.project_id and is_nil(track.closed_at) and
          not is_nil(Accounts.session_user(socket.assigns.session_hash))

      _ ->
        false
    end
  end

  defp guard(socket) do
    if authorized?(socket), do: {:cont, socket}, else: {:halt, redirect(socket, to: "/")}
  end

  defp result(socket, :ok, fun), do: fun.(socket, nil)
  defp result(socket, {:ok, value}, fun), do: fun.(socket, value)
  defp result(socket, {:error, reason}, _), do: error(socket, reason)
  defp error(socket, reason), do: put_flash(socket, :error, Error.from(reason).message)

  defp owner_or_creator?(user, track),
    do: track.role == :owner or track.created_by_login == user.login

  defp invite_url(%{url: url}), do: url
  defp invite_url(_), do: nil

  defp visible_prompt(prompt) do
    prompt = Ravix.Previews.Agent.visible_prompt(prompt)
    Transcript.app_turn_label(prompt) || prompt
  end

  defp upload_error(:too_large), do: "Image is larger than 8 MB."
  defp upload_error(:too_many_files), do: "Attach at most six images."
  defp upload_error(_), do: "Use a PNG, JPEG, GIF, or WebP image."
end
