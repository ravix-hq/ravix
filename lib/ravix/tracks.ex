defmodule Ravix.Tracks do
  @moduledoc """
  Tracks: a worktree, and a conversation about it.

  Everything difficult about this app is in `open/4` below, and it comes
  down to one asymmetry. Making a *conversation* is an API call and takes a
  moment. Making a *worktree* is work on a real machine and takes a turn.
  The two cannot be done atomically, so a track exists in the UI before its
  directory exists on the box, and pretending otherwise would mean either a
  spinner covering the first ten seconds of every track or a prompt box that
  silently fails until the machine catches up.

  So the opening turn is a real turn, sent immediately, and the person
  watches it happen in the transcript. That is not a workaround: it is the
  same decision paddock made about first run, for the same reason: the first
  thing somebody sees is the machine actually doing their work, which is the
  product. The track is `:opening` until the machine answers and `:ready`
  afterwards, and the composer stays live because Ravix saves follow-up
  prompts on the server until the conversation is ready.

  Every user-facing function takes the `%Ravix.Accounts.User{}` and goes
  through one of the three doors in `Ravix.Accounts.Access` first. The
  `_unsafe_` reads at the bottom are the track half of `server/db.ts`, for
  the contexts that have already established ownership.
  """

  import Ecto.Query

  alias Ravix.Accounts.Access
  alias Ravix.Accounts.User
  alias Ravix.Fountain
  alias Ravix.Fountain.Client
  alias Ravix.Hub
  alias Ravix.Ids
  alias Ravix.MachineCache
  alias Ravix.Projects.Project
  alias Ravix.Repo
  alias Ravix.Spec
  alias Ravix.Tracks.{Diff, Files, Follower, Names, Track, TrackMember, Transcript}

  @origin_kinds ~w(branch pr issue blank)
  @image_types ~w(image/png image/jpeg image/gif image/webp)
  # base64 is four characters per three bytes; the cap is on the decoded size.
  @image_max_chars div(8 * 1024 * 1024 * 4, 3)
  @max_images 6

  @typedoc "What the caller may do here."
  @type role :: :owner | :member

  @typedoc "The `Track` of `shared/api.ts`, with atom keys; see `present/2`."
  @type track_map :: %{
          id: String.t(),
          project_id: String.t(),
          conversation_id: String.t() | nil,
          slug: String.t(),
          title: String.t(),
          branch: String.t(),
          workdir: String.t(),
          origin: origin_info(),
          status: :opening | :ready | :running | :failed | :closed,
          stale: boolean(),
          opened_at: DateTime.t() | nil,
          last_active_at: DateTime.t() | nil,
          turn_count: non_neg_integer(),
          created_at: DateTime.t(),
          created_by_login: String.t(),
          people: [map()],
          role: role(),
          unread: boolean()
        }

  @typedoc "How a track was started, the `TrackOriginInfo` of `shared/api.ts`."
  @type origin_info :: %{
          kind: :branch | :pr | :issue | :blank,
          base: String.t() | nil,
          number: integer() | nil,
          title: String.t() | nil,
          url: String.t() | nil
        }

  @typedoc "The ribbon at the top of a track: the four lines Conductor shows on a new thread."
  @type header :: %{
          copy_of: String.t() | nil,
          branched_from: %{branch: String.t(), base: String.t()} | nil,
          created: %{dir: String.t(), files: nil},
          has_setup_script: boolean()
        }

  @type reason ::
          :not_found
          | {:forbidden, String.t()}
          | {:conflict, String.t(), String.t()}
          | {:unprocessable, String.t(), String.t()}
          | {:unavailable, String.t(), String.t()}
          | Fountain.Error.t()
          | :unconfigured
          | term()

  # ── reading ───────────────────────────────────────────────────────────

  @doc """
  `GET /api/projects/:id/tracks`.

  The owner and anybody invited to the whole project see all of its tracks.
  Somebody invited to particular tracks sees those and is not told there
  are others. Same function, because the sidebar asks the same question
  whichever of the three is asking. Read live rather than from the memo,
  because this is what the sidebar's status comes from and a turn that
  ended must not show as running for another five seconds.
  """
  @spec list(User.t(), String.t()) :: {:ok, [track_map()]} | {:error, :not_found}
  def list(%User{} = user, project_id) do
    with %Project{} = project <- live_project(project_id),
         {:ok, access} <- access_of(user.id, project) do
      wide = access in [:owner, :project]

      rows =
        if wide,
          do: _unsafe_tracks_of(project.id),
          else: _unsafe_member_tracks_of(user.id, project.id)

      if not wide and rows == [],
        do: {:error, :not_found},
        else:
          {:ok, present_all(rows, project, user, if(access == :owner, do: :owner, else: :member))}
    else
      _ -> {:error, :not_found}
    end
  end

  defp present_all(rows, project, user, role) do
    live = conversations_of(project)
    reads = Ravix.People.reads_of(user.id, project.id)

    Enum.map(rows, fn row ->
      present(row,
        project: project,
        live: live[row.conversation_id],
        people: Ravix.People.people_of(row.id, project.user_id, project.id),
        role: role,
        last_read: reads[row.id]
      )
    end)
  end

  @doc """
  `GET /api/tracks/:id`: the track, plus the ribbon that sits above it and
  the starter chips.

  The environment is read for one boolean, and it is worth the call: the
  "add a setup script" line in the ribbon is an offer, and an offer that
  keeps appearing after you have accepted it reads as a broken app.
  """
  @spec get(User.t(), String.t()) ::
          {:ok, %{track: track_map(), header: header(), starters: [map()]}} | {:error, reason()}
  def get(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project, role: role}} <-
           Access.track_access(user, track_id),
         {:ok, client} <- fountain() do
      live = conversations_of(project)

      environment =
        case Fountain.get_environment(client, project.environment_id) do
          {:ok, env} -> env
          _ -> nil
        end

      header = %{
        copy_of:
          if(project.repo_full_name,
            do: project.repo_full_name |> String.split("/") |> List.last()
          ),
        branched_from:
          if(track.origin_base, do: %{branch: track.branch, base: track.origin_base}),
        # The file count Conductor shows comes from copying a directory.
        # Nothing here copies anything (a worktree shares the object store),
        # so the honest answer is the directory alone rather than a number
        # invented to match a screenshot.
        created: %{dir: track.slug, files: nil},
        has_setup_script: setup_script?(environment)
      }

      {:ok,
       %{
         track:
           present(track,
             project: project,
             live: live[track.conversation_id],
             people: Ravix.People.people_of(track.id, project.user_id, project.id),
             role: role,
             last_read: Ravix.People.last_read_of(track.id, user.id)
           ),
         header: header,
         starters: Spec.starters(%{has_repo: not is_nil(project.repo_full_name)})
       }}
    end
  end

  # ── opening ───────────────────────────────────────────────────────────

  @doc """
  `POST /api/projects/:id/tracks`: a new line off the main.

  The four ways in (blank, a branch, a pull request, an issue) differ only
  in what the opening turn is told, which is why they are one function with
  an `origin` rather than four. The slug is derived from whatever the origin
  names (a PR's title, a branch's name) because a person naming a directory
  before they have started work is a question with no good answer.

  Open to project members as well as to the owner. Cutting a track is the
  work rather than the machine (it makes a directory and a branch, and
  changes nothing about what is installed or what the box holds), so it sits
  on the `project_access` side of the line. The branch carries the
  *cutter's* login, not the owner's, so the yard reads as who did what.

  `attrs` (string or atom keys): `title`, `slug`, and `origin` with `kind`,
  `base`, `number`, `title`. The opening turn is sent in the background
  when the machine already exists (it is a turn on a machine that may still
  be booting, so it can take a minute, and the page is already watching the
  transcript it will appear in); `opening_turn: :sync` waits for it, which
  tests want.
  """
  @spec open(User.t(), String.t(), map(), opening_turn: :async | :sync) ::
          {:ok, track_map()} | {:error, reason()}
  def open(%User{} = user, project_id, attrs, opts \\ []) do
    attrs = stringify(attrs)

    with {:ok, %{project: project, role: role}} <- Access.project_access(user, project_id),
         {:ok, client} <- fountain(),
         :ok <- Ravix.Projects.prepare_machine(project, client),
         {:ok, machine} <- MachineCache.machine_of(client, project),
         plan = plan(user, project, attrs, machine),
         {:ok, track} <- cut(client, plan) do
      if machine,
        do:
          send_opening_turn(
            client,
            track,
            project,
            plan.origin,
            Keyword.get(opts, :opening_turn, :async)
          ),
        # It went with the launch. The track is open as far as Fountain is
        # concerned; the worktree lands when that turn does.
        else: _unsafe_mark_opened(track.id)

      # A first track provisions the machine, so what the memo holds is out
      # of date the moment this returns.
      MachineCache.forget_project(project.id)
      publish_tracks(project.id)
      {:ok, present(track, project: project, live: nil, role: role)}
    end
  end

  # Everything a new track is called, decided before anything wakes the box:
  # the conversation Fountain is asked for, and the row that will remember it.
  defp plan(user, project, attrs, machine) do
    id = Ecto.UUID.generate()
    origin = read_origin(attrs["origin"], project)
    # Every track this project has ever had, closed ones included; see
    # `Ravix.Tracks.Names.name_track/2` for why a closed track's name is still spent.
    taken = project.id |> _unsafe_tracks_of(true) |> Enum.map(& &1.slug)
    title = text(attrs["title"], 200) |> non_empty() || default_title(origin, taken)
    slug = free_slug(project.id, text(attrs["slug"], 60) |> non_empty() || title)

    branch =
      if origin.kind == "pr" and origin.base,
        do: origin.base,
        else: Ids.branch_for(user.login, slug, id)

    %{
      origin: origin,
      conversation: %{
        agent_id: project.agent_id,
        environment_id: project.environment_id,
        vault_id: project.vault_id,
        sandbox_id: machine && machine.sandbox_id,
        title: title,
        channel_id: Ids.track_channel(project.id, slug, project.rev),
        # On the launch that *provisions* the machine the opening turn rides
        # along, because a fresh conversation with no prompt is what made
        # provisioning start answering 422. On an attach it is sent separately
        # afterwards, where a machine at capacity can be reported and retried.
        prompt: if(machine, do: nil, else: opening_prompt(slug, branch, project, origin))
      },
      row: %{
        id: id,
        project_id: project.id,
        slug: slug,
        title: title,
        branch: branch,
        workdir: Ids.workdir_for(slug),
        origin_kind: origin.kind,
        origin_base: origin.base,
        origin_number: origin.number,
        origin_title: origin.title,
        origin_url: origin_url(project, origin),
        rev: project.rev,
        created_by_login: user.login
      }
    }
  end

  # The conversation on Fountain, then the row that remembers it.
  defp cut(client, %{conversation: conversation, row: row}) do
    with {:ok, %{"id" => conversation_id}} <- Fountain.create_conversation(client, conversation) do
      _unsafe_create_track(Map.put(row, :conversation_id, conversation_id))
    end
  end

  @doc """
  `POST /api/tracks/:id/retry`: send the opening turn again.

  A machine at capacity is the ordinary case when two tracks are opened at
  once (the box runs one turn at a time), so an opening turn that did not
  send is not the failure it looks like. But a track whose worktree was never
  cut is one a person needs to be able to retry, which this is for. The
  outcome is published as a `turn` event either way; `:ok` means the retry
  was made, not that it landed.
  """
  @spec retry(User.t(), String.t()) :: :ok | {:error, reason()}
  def retry(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id),
         {:ok, client} <- fountain(),
         :ok <- Ravix.Projects.prepare_machine(project, client) do
      send_opening_turn(client, track, project, origin_of(track), :sync)
      :ok
    end
  end

  defp send_opening_turn(_client, %Track{conversation_id: nil}, _project, _origin, _mode), do: :ok

  defp send_opening_turn(client, track, project, origin, :async) do
    {:ok, _pid} =
      Task.Supervisor.start_child(Ravix.TaskSupervisor, fn ->
        send_opening_turn(client, track, project, origin, :sync)
      end)

    :ok
  end

  defp send_opening_turn(client, track, project, origin, :sync) do
    prompt = opening_prompt(track.slug, track.branch, project, origin)

    case Fountain.prompt(client, track.conversation_id, prompt) do
      :ok ->
        _unsafe_mark_opened(track.id)
        Hub.publish(project.id, "turn", %{track_id: track.id, status: :ready})

      {:error, reason} ->
        require Logger
        Logger.error("ravix: opening turn for track #{track.id} did not send: #{inspect(reason)}")
        Hub.publish(project.id, "turn", %{track_id: track.id, status: :failed})
    end

    :ok
  end

  defp opening_prompt(slug, branch, project, origin) do
    Spec.open_track_prompt(%{
      slug: slug,
      branch: branch,
      repo_path: repo_path(project),
      origin: %{kind: origin.kind, base: origin.base, number: origin.number, title: origin.title}
    })
  end

  # ── talking to it ─────────────────────────────────────────────────────

  @doc """
  `POST /api/tracks/:id/prompt`: accept into the database before
  acknowledging; `Ravix.PromptQueue` owns delivery.

  `payload` (string or atom keys): `prompt`, `images` (`data` base64 and
  `media_type`, at most six, 8 MB each decoded) and `request_id`, the
  caller's idempotency key. The cap on images is on the decoded size and on
  the count, because the browser is not the only thing that can post here
  and an unbounded list of megabyte data URLs is a way to fill the
  machine's memory rather than a feature.
  """
  @spec prompt(User.t(), String.t(), map()) :: {:ok, term()} | {:error, reason()}
  def prompt(%User{} = user, track_id, payload) do
    payload = stringify(payload)

    with {:ok, %{track: track}} <- Access.track_access(user, track_id),
         {:ok, _client} <- fountain(),
         {:ok, images} <- read_images(payload["images"]),
         text = text(payload["prompt"], 100_000),
         :ok <-
           check(
             String.trim(text) != "" or images != [],
             {:unprocessable, "empty_prompt", "Say something."}
           ),
         :ok <-
           check(
             track.conversation_id,
             {:conflict, "not_open", "This track has no conversation yet."}
           ),
         :ok <-
           check(is_nil(track.closed_at), {:conflict, "closed_track", "This track is closed."}) do
      Ravix.PromptQueue.enqueue(track.id, user.id, user.login, payload["request_id"], %{
        prompt: text,
        images: images
      })
    end
  end

  @doc """
  `POST /api/tracks/:id/read`: this person has seen it up to now.

  Sent by the page when a track is open and settled, rather than inferred
  from the read: opening a track to glance at the branch name is not reading
  three turns of output, and a read mark set by the fetch would clear the
  dot before anybody looked.
  """
  @spec mark_read(User.t(), String.t()) :: :ok | {:error, reason()}
  def mark_read(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id) do
      Ravix.People.mark_read(track.id, user.id, DateTime.utc_now())
      publish_tracks(project.id)
    end
  end

  @doc "`POST /api/tracks/:id/interrupt`: stop the running turn."
  @spec interrupt(User.t(), String.t()) :: :ok | {:error, reason()}
  def interrupt(%User{} = user, track_id) do
    with {:ok, %{track: track}} <- Access.track_access(user, track_id),
         {:ok, client} <- fountain(),
         :ok <-
           check(
             track.conversation_id,
             {:conflict, "not_open", "This track has no conversation yet."}
           ) do
      Fountain.interrupt(client, track.conversation_id)
    end
  end

  @doc """
  `POST /api/tracks/:id/presence`: I am here, and possibly typing.

  One function for both because they are one heartbeat: the page is already
  saying "still watching" and `typing` rides along rather than opening a
  second channel that could disagree with the first about whether somebody
  is still in the room. Called from the page's own process, which is what
  `Ravix.Presence` tracks. Returns who is in the room now.
  """
  @spec beat(User.t(), String.t(), boolean()) ::
          {:ok, [Ravix.Presence.presence()]} | {:error, :not_found}
  def beat(%User{} = user, track_id, typing?) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id) do
      {:ok, Ravix.Presence.beat(track.id, project.id, user, typing?)}
    end
  end

  @doc "The polite half of presence: somebody closing a track, rather than lapsing out of it."
  @spec leave(User.t(), String.t()) :: :ok
  def leave(%User{id: user_id}, track_id), do: Ravix.Presence.leave(track_id, user_id)

  @doc """
  `GET /api/tracks/:id/events`: the transcript so far, both halves of it.

  The prompts and the output live in two different places on Fountain and
  are joined on `turn_id`. Joining them here rather than in the page is not
  tidiness: it is one round trip instead of two on the call that gates the
  first paint of a track. A conversation too new to have turns is ordinary,
  not an error. The page then follows the rest through
  `Ravix.Tracks.Follower.subscribe/2` from the page's `last_event_id`.
  """
  @spec events(User.t(), String.t(), keyword()) :: {:ok, Transcript.page()} | {:error, reason()}
  def events(%User{} = user, track_id, _opts \\ []) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id),
         {:ok, client} <- fountain() do
      if track.conversation_id,
        do: read_transcript(client, track.conversation_id, project.runtime),
        else: {:ok, Transcript.empty(project.runtime)}
    end
  end

  defp read_transcript(client, conversation_id, runtime) do
    turns =
      case Fountain.turns(client, conversation_id) do
        {:ok, turns} -> turns
        _ -> []
      end

    with {:ok, log} <- Fountain.events(client, conversation_id) do
      {:ok, Transcript.page(turns, log, runtime)}
    end
  end

  @doc """
  `PATCH /api/tracks/:id`: rename the label, and only the label.

  A track is named before anybody knows what it is (after a pull request, a
  branch, or the yard's own list), so the name it opened with is frequently
  the wrong one by the end. The slug, the branch and the worktree
  deliberately do not follow it: those were cut on a real machine when the
  track opened, and a directory somebody is working in is not something a
  rename box should move under them. Somebody invited to help on one branch
  is not somebody who relabels it in everybody else's rail, but whoever cut
  it named it in the first place.
  """
  @spec rename(User.t(), String.t(), String.t()) :: :ok | {:error, reason()}
  def rename(%User{} = user, track_id, title) do
    with {:ok, %{track: track, project: project, role: role}} <-
           Access.track_access(user, track_id),
         :ok <- Access.require_owner_or_cutter(role, user, track, "rename a track"),
         title when is_binary(title) <-
           text(title, 200) |> non_empty() ||
             {:error, {:unprocessable, "no_title", "A track needs a name."}} do
      _unsafe_rename_track(track.id, title)
      publish_tracks(project.id)
    end
  end

  @doc """
  `DELETE /api/tracks/:id`: close the track and take the worktree away.

  The branch is left alone unless `delete_branch: true`: it may be pushed,
  it may be an open pull request, and "close this tab" is not a gesture that
  should delete somebody's work. The worktree goes because it is a directory
  on a shared disk that nothing else will ever use, and `force: true` says
  to discard uncommitted changes in it on purpose.

  A project with no repository still has a directory per track (the opening
  turn made one with `mkdir -p`), so the close turn is sent either way and
  `Ravix.Spec.close_track_prompt/1` decides between `git worktree remove`
  and `rm -rf`. Best effort, and on purpose: a machine that is asleep, at
  capacity or gone must not stop somebody closing a track. The row is
  Ravix's, and the worktree is tidied on the next survey if this turn never
  lands. Closing ends the track for everybody in it, so it is the owner's
  call, or the cutter's own; for anybody else the way out is to leave.
  """
  @spec close(User.t(), String.t(), force: boolean(), delete_branch: boolean()) ::
          :ok | {:error, reason()}
  def close(%User{} = user, track_id, opts \\ []) do
    with {:ok, %{track: track, project: project, role: role}} <-
           Access.track_access(user, track_id),
         :ok <- Access.require_owner_or_cutter(role, user, track, "close a track"),
         {:ok, client} <- fountain() do
      Ravix.PromptQueue.cancel_track(track.id)
      Ravix.Previews.stop_service(track.id, true)

      if track.conversation_id do
        prompt =
          Spec.close_track_prompt(%{
            slug: track.slug,
            repo_path: repo_path(project),
            force: Keyword.get(opts, :force, false) == true,
            delete_branch: if(Keyword.get(opts, :delete_branch, false) == true, do: track.branch)
          })

        Fountain.prompt(client, track.conversation_id, prompt)
        Fountain.terminate(client, track.conversation_id)
      end

      _unsafe_close_track(track.id)
      MachineCache.forget_project(project.id)
      publish_tracks(project.id)
    end
  end

  @doc """
  Every open track of a project, closed in the database, because the disk
  they were on is gone. For `Ravix.Projects` on a rebuild or a destroy,
  which has already terminated the conversations and stopped the previews;
  this is the row half. `reason` is `:rebuild` or `:destroy`, for the log.
  """
  @spec close_all_for_rebuild(Project.t(), atom()) :: :ok
  def close_all_for_rebuild(%Project{id: project_id}, _reason) do
    Enum.each(_unsafe_tracks_of(project_id), fn track ->
      Ravix.PromptQueue.cancel_track(track.id)
      _unsafe_close_track(track.id)
    end)
  end

  # ── reading a track's directory ───────────────────────────────────────

  @doc "`GET /api/tracks/:id/files?path=`: one directory, confined to the worktree. Free; it does not wake a parked box."
  @spec files(User.t(), String.t(), String.t() | nil) ::
          {:ok, Files.listing()} | {:error, reason()}
  def files(%User{} = user, track_id, path) do
    with {:ok, track, client, sandbox_id} <- machine_read(user, track_id),
         {:ok, raw} <- Fountain.listing(client, sandbox_id, confine(track.workdir, path)) do
      {:ok, Files.present_listing(raw)}
    end
  end

  @doc "`GET /api/tracks/:id/file?path=`: one file, confined to the worktree."
  @spec file(User.t(), String.t(), String.t() | nil) ::
          {:ok, Files.content()} | {:error, reason()}
  def file(%User{} = user, track_id, path) do
    with {:ok, track, client, sandbox_id} <- machine_read(user, track_id),
         {:ok, raw} <- Fountain.file(client, sandbox_id, confine(track.workdir, path)) do
      {:ok, Files.present_file(raw)}
    end
  end

  @doc "`GET /api/tracks/:id/diff`: `git diff` in this track's worktree, parsed per file."
  @spec diff(User.t(), String.t()) ::
          {:ok,
           %{
             path: String.t(),
             repo_root: String.t() | nil,
             diff: String.t(),
             truncated: boolean(),
             files: [Diff.file()]
           }}
          | {:error, reason()}
  def diff(%User{} = user, track_id) do
    with {:ok, track, client, sandbox_id} <- machine_read(user, track_id),
         {:ok, raw} <- Fountain.diff(client, sandbox_id, track.workdir) do
      diff = raw["diff"] || ""

      {:ok,
       %{
         path: raw["path"],
         repo_root: raw["repo_root"],
         diff: diff,
         truncated: raw["truncated"] == true,
         files: summarize_diff(diff)
       }}
    end
  end

  @doc "A unified diff, counted per file. See `Ravix.Tracks.Diff.summarize/1`."
  @spec summarize_diff(String.t()) :: [Diff.file()]
  defdelegate summarize_diff(diff), to: Diff, as: :summarize

  @doc "A path, pinned inside the track's own worktree. See `Ravix.Tracks.Files.confine/2`."
  @spec confine(String.t(), String.t() | nil) :: String.t()
  defdelegate confine(root, requested), to: Files

  defp machine_read(user, track_id) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id),
         {:ok, client} <- fountain(),
         {:ok, machine} <- MachineCache.machine_of(client, project),
         :ok <- check(machine, {:conflict, "no_machine", "This project has no machine yet."}) do
      {:ok, track, client, machine.sandbox_id}
    end
  end

  # ── GitHub, for this branch ───────────────────────────────────────────

  @doc """
  `GET /api/tracks/:id/checks`: the Checks tab.

  A branch that has never been pushed is the ordinary state of a new track,
  and the report says so (`pushed: false`) rather than returning an empty
  list that looks like a failure with no runs. A member's own branch and its
  checks are the point of inviting them, so this is track access rather
  than project ownership.
  """
  @spec checks(User.t(), String.t()) :: {:ok, Ravix.GitHub.checks_report()} | {:error, reason()}
  def checks(%User{} = user, track_id) do
    with {:ok, app} <- github(),
         {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id),
         :ok <- require_repo(project, "This project has no repository.") do
      Ravix.GitHub.checks(app, project.installation_id, project.repo_full_name, track.branch, %{
        created_at: track.created_at,
        origin_number: if(track.origin_kind == "pr", do: track.origin_number)
      })
    end
  end

  @doc """
  `POST /api/tracks/:id/pull`: open a pull request for this track's branch.

  Ravix opens it rather than asking the agent to, when the agent has no
  `gh` on the box. It is authored by the App, which is honest (a machine
  opened it), where a token borrowed from the person would put their name on
  work they have not read. Open to members, and that is a decision rather
  than an oversight: a member can already prompt the agent, the machine
  already holds a credential that can push, and the agent will open a pull
  request if asked. A button that refused what the prompt box allows would
  be theatre.

  `attrs` (string or atom keys): `title` (the track's by default), `base`
  (the project's default branch), `body`, `draft` (true unless false).
  """
  @spec open_pull(User.t(), String.t(), map()) :: {:ok, map()} | {:error, reason()}
  def open_pull(%User{} = user, track_id, attrs) do
    attrs = stringify(attrs)

    with {:ok, app} <- github(),
         {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id),
         :ok <- require_repo(project, "This project has no repository.") do
      Ravix.GitHub.open_pull(app, project.installation_id, project.repo_full_name, %{
        head: track.branch,
        base: text(attrs["base"], 200) |> non_empty() || project.default_branch || "main",
        title: text(attrs["title"], 200) |> non_empty() || track.title,
        body:
          text(attrs["body"], 20_000) |> non_empty() || "Opened from Ravix track `#{track.slug}`.",
        draft: attrs["draft"] != false
      })
    end
  end

  # ── the machine, for the panels ───────────────────────────────────────

  @doc """
  The project's machine, read from its conversations through the memo.
  See `Ravix.MachineCache.machine_of/3`; `fresh: true` asks Fountain.
  """
  @spec machine_of(Project.t(), keyword()) :: {:ok, MachineCache.machine()} | {:error, reason()}
  def machine_of(%Project{} = project, opts \\ []) do
    with {:ok, client} <- fountain(), do: MachineCache.machine_of(client, project, opts)
  end

  @doc "The sprite behind a sandbox, or nil if it is not on Sprites at all. See `Ravix.MachineCache.sprite_for/3`."
  @spec sprite_for(String.t()) :: String.t() | nil
  def sprite_for(sandbox_id) do
    case fountain() do
      {:ok, client} -> MachineCache.sprite_for(client, sandbox_id)
      _ -> nil
    end
  end

  # Every conversation on the project's agent, by id, read live, not from the
  # memo, because this is what the sidebar's status comes from and a turn
  # that ended must not show as running for another five seconds. The fresh
  # answer is written through, so a burst of machine reads right after it is
  # free. A Fountain that cannot be reached is an empty map: every track
  # then reads as `:ready` or `:opening` rather than nothing loading at all.
  defp conversations_of(project) do
    with {:ok, client} <- fountain(),
         {:ok, all} <- MachineCache.conversations(client, project, fresh: true) do
      Map.new(all, &{&1["id"], &1})
    else
      _ -> %{}
    end
  end

  # ── the Track map ─────────────────────────────────────────────────────

  @doc """
  The `Track` of `shared/api.ts` for a row.

  Options: `project` (required for `stale`), `live` (the conversation as
  Fountain lists it, string keys, or nil), `people`, `role` (`:owner` by
  default) and `last_read` (a `DateTime`). The revision is in the channel id
  the conversation already carries, so "is this track behind?" is a
  comparison rather than a stored flag. A track nobody has opened is unread
  the moment the machine says anything; one whose last activity predates
  your last look is not. The comparison is against `last_active_at` rather
  than a turn count so a streamed reply marks it unread as it arrives.
  """
  @spec present(Track.t(), keyword()) :: track_map()
  def present(%Track{} = row, opts \\ []) do
    project = Keyword.get(opts, :project)
    live = Keyword.get(opts, :live)
    last_active = parse_time(live && live["last_active_at"])

    %{
      id: row.id,
      project_id: row.project_id,
      conversation_id: row.conversation_id,
      slug: row.slug,
      title: row.title,
      branch: row.branch,
      workdir: row.workdir,
      origin: origin_info(row),
      status: status_of(row, live),
      stale: not is_nil(project) and row.rev < project.rev,
      opened_at: row.opened_at,
      last_active_at: last_active,
      turn_count: (live && live["turn_count"]) || 0,
      created_at: row.created_at,
      created_by_login: row.created_by_login,
      people: Keyword.get(opts, :people, []),
      role: Keyword.get(opts, :role, :owner),
      unread: unread?(last_active, Keyword.get(opts, :last_read))
    }
  end

  @doc "How a track was started, from its row."
  @spec origin_info(Track.t()) :: origin_info()
  def origin_info(%Track{} = row) do
    %{
      kind:
        if(row.origin_kind in @origin_kinds, do: String.to_atom(row.origin_kind), else: :blank),
      base: row.origin_base,
      number: row.origin_number,
      title: row.origin_title,
      url: row.origin_url
    }
  end

  defp status_of(%Track{closed_at: closed}, _live) when not is_nil(closed), do: :closed
  defp status_of(_row, %{"status" => "running"}), do: :running
  defp status_of(_row, %{"status" => "failed"}), do: :failed
  defp status_of(%Track{opened_at: nil}, _live), do: :opening
  defp status_of(_row, _live), do: :ready

  defp unread?(nil, _last_read), do: false
  defp unread?(_last_active, nil), do: true
  defp unread?(last_active, last_read), do: DateTime.compare(last_active, last_read) == :gt

  defp parse_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, time, _offset} -> time
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  # ── the pieces `open/4` is made of ────────────────────────────────────

  defp read_origin(raw, project) when is_map(raw) do
    kind = if raw["kind"] in @origin_kinds, do: raw["kind"], else: "blank"

    if kind == "blank" do
      %{kind: "blank", base: project.default_branch, number: nil, title: nil}
    else
      %{
        kind: kind,
        base: text(raw["base"], 200) |> non_empty() || project.default_branch,
        number: number(raw["number"]),
        title: text(raw["title"], 200) |> non_empty()
      }
    end
  end

  defp read_origin(_raw, project), do: read_origin(%{}, project)

  # The origin of a track that already exists, for the retry.
  defp origin_of(%Track{} = row) do
    %{
      kind: row.origin_kind,
      base: row.origin_base,
      number: row.origin_number,
      title: row.origin_title
    }
  end

  # What a track is called when nobody said. The order is deliberate: a track
  # that came from a pull request, an issue or a branch already has the best
  # name available (the one the work is called everywhere else), and
  # inventing a prettier one would break the join between the sidebar and
  # GitHub. Only a track started from nothing gets a yard name.
  defp default_title(%{kind: "pr", number: n} = origin, _taken) when is_integer(n),
    do: origin.title || "PR ##{n}"

  defp default_title(%{kind: "issue", number: n} = origin, _taken) when is_integer(n),
    do: origin.title || "Issue ##{n}"

  defp default_title(%{kind: "branch", base: base}, _taken) when is_binary(base) and base != "",
    do: base

  defp default_title(_origin, taken), do: Names.name_track(taken)

  defp origin_url(%Project{repo_full_name: repo}, %{number: n} = origin)
       when is_binary(repo) and is_integer(n) do
    kind = if origin.kind == "pr", do: "pull", else: "issues"
    "https://github.com/#{repo}/#{kind}/#{n}"
  end

  defp origin_url(_project, _origin), do: nil

  # A slug nobody else is using. A slug is a directory on a real machine, so
  # a clash is not a naming inconvenience: it is two tracks writing to one
  # worktree. Suffixing is better than refusing: somebody opening a second
  # track from the same pull request means it, and being told "that name is
  # taken" about a name they never chose is a dead end.
  defp free_slug(project_id, from) do
    base = Ids.slugify(from)

    if _unsafe_slug_taken?(project_id, base), do: suffixed_slug(project_id, base), else: base
  end

  defp suffixed_slug(project_id, base) do
    Enum.find_value(2..99, fn n ->
      candidate = "#{base}-#{n}"
      unless _unsafe_slug_taken?(project_id, candidate), do: candidate
    end) ||
      "#{base}-#{Integer.to_string(System.system_time(:millisecond), 36) |> String.downcase()}"
  end

  defp repo_path(%Project{repo_full_name: repo}) when is_binary(repo) and repo != "",
    do: Ids.mount_path_for(repo)

  defp repo_path(_project), do: nil

  defp setup_script?(%{"setup_script" => script}) when is_binary(script),
    do: String.trim(script) != ""

  defp setup_script?(_), do: false

  # What the page may attach to a prompt. Fountain takes `{data, media_type}`
  # with the data base64.
  defp read_images(raw) when is_list(raw) do
    raw
    |> Enum.take(@max_images)
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      item = if is_map(item), do: stringify(item), else: %{}
      data = item["data"]
      type = item["media_type"]

      cond do
        not is_binary(data) or type not in @image_types ->
          {:cont, {:ok, acc}}

        String.length(data) > @image_max_chars ->
          {:halt,
           {:error, {:unprocessable, "image_too_large", "That image is larger than 8 MB."}}}

        true ->
          {:cont, {:ok, [%{data: data, media_type: type} | acc]}}
      end
    end)
    |> case do
      {:ok, images} -> {:ok, Enum.reverse(images)}
      error -> error
    end
  end

  defp read_images(_raw), do: {:ok, []}

  # The three ways in: owner, whole project, or particular tracks. The port
  # of `accessOf` in projects.ts, kept here so the list does not depend on
  # `Ravix.Projects` for four lines.
  defp access_of(user_id, %Project{} = project) do
    cond do
      project.user_id == user_id -> {:ok, :owner}
      Access.project_member?(project.id, user_id) -> {:ok, :project}
      _unsafe_member_tracks_of(user_id, project.id) != [] -> {:ok, :tracks}
      true -> {:error, :not_found}
    end
  end

  defp live_project(project_id) when is_binary(project_id) do
    case Repo.get(Project, project_id) do
      %Project{archived_at: nil} = project -> project
      _ -> nil
    end
  end

  defp live_project(_), do: nil

  defp publish_tracks(project_id),
    do: Hub.publish(project_id, "tracks", %{project_id: project_id})

  defp fountain do
    client = Fountain.client()
    if Client.configured?(client), do: {:ok, client}, else: {:error, :unconfigured}
  end

  defp github do
    case Ravix.Config.github() do
      nil ->
        {:error,
         {:unavailable, "no_github",
          "This Ravix deployment has no GitHub App configured, so it cannot see repositories."}}

      app ->
        {:ok, app}
    end
  end

  defp require_repo(%Project{repo_full_name: repo, installation_id: installation}, _message)
       when is_binary(repo) and repo != "" and is_integer(installation),
       do: :ok

  defp require_repo(_project, message), do: {:error, {:conflict, "no_repo", message}}

  defp check(condition, _error) when condition not in [nil, false], do: :ok
  defp check(_condition, error), do: {:error, error}

  defp text(value, max) when is_binary(value), do: value |> String.slice(0, max) |> String.trim()
  defp text(_value, _max), do: ""

  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  defp number(n) when is_integer(n) and n > 0, do: n

  defp number(n) when is_binary(n) do
    case Integer.parse(n) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp number(_), do: nil

  defp stringify(attrs) when is_map(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}

  # ── the rows (server/db.ts, the track half) ───────────────────────────
  #
  # Unscoped, as the name says: each is called beside a door in
  # `Ravix.Accounts.Access` that already answered, or by a context that
  # holds the project.

  @doc "A track row. The caller brings the id, since the branch name carries it."
  @spec _unsafe_create_track(map()) :: {:ok, Track.t()} | {:error, Ecto.Changeset.t()}
  def _unsafe_create_track(attrs), do: %Track{} |> Track.changeset(attrs) |> Repo.insert()

  @doc "One track by id, closed or not."
  @spec _unsafe_get_track(String.t()) :: Track.t() | nil
  def _unsafe_get_track(id) when is_binary(id), do: Repo.get(Track, id)
  def _unsafe_get_track(_id), do: nil

  @doc "The track a conversation belongs to."
  @spec _unsafe_track_by_conversation(String.t()) :: Track.t() | nil
  def _unsafe_track_by_conversation(conversation_id) when is_binary(conversation_id),
    do: Repo.get_by(Track, conversation_id: conversation_id)

  def _unsafe_track_by_conversation(_), do: nil

  @doc "A project's tracks, oldest first: the open ones, or every one it ever had."
  @spec _unsafe_tracks_of(String.t(), boolean()) :: [Track.t()]
  def _unsafe_tracks_of(project_id, include_closed? \\ false) do
    query = from(t in Track, where: t.project_id == ^project_id, order_by: t.created_at)
    query = if include_closed?, do: query, else: where(query, [t], is_nil(t.closed_at))
    Repo.all(query)
  end

  @doc "The open tracks of one project this person was named on, oldest first."
  @spec _unsafe_member_tracks_of(String.t(), String.t()) :: [Track.t()]
  def _unsafe_member_tracks_of(user_id, project_id) do
    Repo.all(
      from(t in Track,
        join: m in TrackMember,
        on: m.track_id == t.id,
        where: m.user_id == ^user_id and t.project_id == ^project_id and is_nil(t.closed_at),
        order_by: t.created_at
      )
    )
  end

  @doc "Whether a slug is free right now: the unique index enforces it, this explains it."
  @spec _unsafe_slug_taken?(String.t(), String.t()) :: boolean()
  def _unsafe_slug_taken?(project_id, slug) do
    Repo.exists?(
      from(t in Track,
        where: t.project_id == ^project_id and t.slug == ^slug and is_nil(t.closed_at)
      )
    )
  end

  @doc "Give a track its conversation, in the instant between the two."
  @spec _unsafe_attach_conversation(String.t(), String.t()) :: :ok
  def _unsafe_attach_conversation(track_id, conversation_id) do
    update_track(track_id, conversation_id: conversation_id)
  end

  @doc "The opening turn reported back. Idempotent: the first time stands."
  @spec _unsafe_mark_opened(String.t()) :: :ok
  def _unsafe_mark_opened(track_id) do
    Repo.update_all(from(t in Track, where: t.id == ^track_id and is_nil(t.opened_at)),
      set: [opened_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc "Rename the label, and only the label."
  @spec _unsafe_rename_track(String.t(), String.t()) :: :ok
  def _unsafe_rename_track(track_id, title), do: update_track(track_id, title: title)

  @doc "Close the row. Waiting prompts are cancelled by the caller through `Ravix.PromptQueue.cancel_track/1`."
  @spec _unsafe_close_track(String.t()) :: :ok
  def _unsafe_close_track(track_id) do
    Repo.update_all(from(t in Track, where: t.id == ^track_id and is_nil(t.closed_at)),
      set: [closed_at: DateTime.utc_now()]
    )

    :ok
  end

  defp update_track(track_id, changes) do
    Repo.update_all(from(t in Track, where: t.id == ^track_id), set: changes)
    :ok
  end

  @doc "A page subscribing to a track's live transcript. See `Ravix.Tracks.Follower.subscribe/2`."
  @spec follow(User.t(), String.t(), keyword()) :: :ok | {:error, reason()}
  def follow(%User{} = user, track_id, opts \\ []) do
    with {:ok, %{track: track}} <- Access.track_access(user, track_id),
         :ok <-
           check(
             track.conversation_id,
             {:conflict, "not_open", "This track has no conversation yet."}
           ) do
      Follower.subscribe(track.id, Keyword.put(opts, :conversation_id, track.conversation_id))
    end
  end
end
