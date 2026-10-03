defmodule Ravix.Terminal do
  @moduledoc """
  The terminal, and the run panel, which are the same thing twice.

  Both are `exec/3`. The difference is what the page sends: a line somebody
  typed, or the project's run command. Making them one function rather than
  two is not tidiness: a run command is a shell command in a directory, and
  giving it its own entry point would give it its own idea of where it
  runs, which is exactly the bug this app is built to prevent.

  Two constraints shape everything here.

  **Out of band.** These commands go to Sprites, not to Fountain. They are
  not turns: they do not appear in the transcript, they do not queue behind
  the agent's one-turn-at-a-time lock, and you can run `git status` while
  the agent is mid-edit. That is the feature. It is also why
  `Ravix.Sprites.resolve_cwd/2` pins every command inside the track's own
  worktree: the terminal must not be the hole in the one rule the agent is
  told three times to follow.

  **Not a PTY.** One request in, one response out. `ls`, `git log`,
  `npm test` are exactly right. `vim`, `top` and anything that wants a tty
  are not, and the panel says so above the prompt rather than letting
  somebody find out by hanging for sixty seconds.

  ## Interactive terminals

  For those there are terminal tabs (RAV-54): a real shell with a
  pseudo-terminal on the same machine, over Sprites' exec WebSocket
  (`Ravix.Sprites.Pty`). A tab is a `Ravix.Terminal.Tab` row --- one
  person's, on one track --- and a page attaches to it with `attach/5`,
  which starts a `Ravix.Terminal.Shell` owned by the page. The shell runs
  in the track's worktree, is out of band in the same way `exec/3` is, and
  keeps running while the page reconnects; `close_tab/3` ends it.

  Every entry point below establishes track access first, and `attach/5`
  checks the session the page was opened with as well: the `Shell` goes on
  checking both for as long as it lives.
  """

  alias Ravix.Accounts
  alias Ravix.Accounts.Access
  alias Ravix.Accounts.User
  alias Ravix.Sprites
  alias Ravix.Sprites.Pty
  alias Ravix.Terminal.{Shell, Store, Tab}
  alias Ravix.Tracks
  alias Ravix.Tracks.Sleep

  # Enough for a server, a console and a shell to look around in, twice
  # over. Each is a process on the machine and a socket on this server.
  @max_tabs 6

  # What a terminal starts at before the browser has measured itself.
  @default_size %{cols: 80, rows: 24}

  defmodule Request do
    @moduledoc """
    One command, as somebody asked for it.

    `Ravix.Terminal.exec/3` used to take a bare map and pull three keys out
    of it by string --- after running it through a private `stringify/1`,
    because the page sends atoms and a JSON caller would send strings, and
    the same two-line helper was written out in `Ravix.Tracks` as well. The
    values were then hand-shaped by a private `text/2` and a four-clause
    `timeout_sec/1` on the way past.

    A changeset does all of that in one place, and the shape it produces has
    a name, so nothing downstream addresses a field by a string and a
    misspelling fails where it is written.

    ## Two of these three are clamped, not refused

    A command longer than the cap is truncated and a timeout outside the
    range is pulled to the nearest end, because neither is somebody making a
    mistake: the browser can send a long paste and an old client can send a
    number this version no longer allows, and the useful answer to both is
    to run the command. An empty command is the one refusal, because there
    is nothing to run.
    """

    use Ecto.Schema

    import Ecto.Changeset

    @max_timeout_sec 120
    @default_timeout_sec 60
    @max_command_chars 8_000

    @type t :: %__MODULE__{
            command: String.t(),
            cwd: String.t() | nil,
            timeout_sec: pos_integer()
          }

    @primary_key false
    embedded_schema do
      field :command, :string, default: ""
      field :cwd, :string
      field :timeout_sec, :integer, default: @default_timeout_sec
    end

    @doc "The ceiling on one command, in seconds. A build is fine; a server is not."
    @spec max_timeout_sec() :: pos_integer()
    def max_timeout_sec, do: @max_timeout_sec

    @doc "How long a command runs when nobody says."
    @spec default_timeout_sec() :: pos_integer()
    def default_timeout_sec, do: @default_timeout_sec

    @doc "How much of a command is kept."
    @spec max_command_chars() :: pos_integer()
    def max_command_chars, do: @max_command_chars

    @doc """
    A request out of whatever the caller has, or the changeset saying the
    command is empty.

    Keys may be strings or atoms: the track page sends atoms, and this is a
    context function rather than a private one.
    """
    @spec parse(term()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
    def parse(%__MODULE__{} = request), do: {:ok, request}

    def parse(%{} = attrs) do
      attrs = normalize_keys(attrs)

      %__MODULE__{}
      |> cast(attrs, [:command, :cwd], empty_values: [])
      |> clamp_command()
      |> put_change(:timeout_sec, timeout_sec(attrs["timeout_sec"]))
      |> apply_action(:insert)
    end

    def parse(_other), do: parse(%{})

    defp clamp_command(changeset) do
      command = changeset |> get_field(:command) |> trim()

      cond do
        not is_binary(command) -> add_error(changeset, :command, "Type a command.")
        command == "" -> add_error(changeset, :command, "Type a command.")
        true -> put_change(changeset, :command, command)
      end
    end

    defp trim(value) when is_binary(value),
      do: value |> String.slice(0, @max_command_chars) |> String.trim()

    defp trim(value), do: value

    # `cast/4` drops a value it cannot read as an integer, so the default
    # stands for both "not sent" and "not a number" --- which is what the
    # four clauses of the old `timeout_sec/1` added up to.
    # Deliberately not `cast/4`'s. A timeout it could not read would be an
    # error on the changeset, and a bad timeout is not a refusal: nobody is
    # helped by being told their command will not run because a number they
    # did not type is not a number. Out of range is pulled to the nearest end
    # for the same reason --- an old client sending a number this version no
    # longer allows still wants its command run. These are the four clauses
    # of the old private `timeout_sec/1`, unchanged in what they decide.
    defp timeout_sec(value) when is_integer(value), do: value |> max(1) |> min(@max_timeout_sec)

    defp timeout_sec(value) when is_binary(value) do
      case Integer.parse(value) do
        {n, ""} -> timeout_sec(n)
        _ -> @default_timeout_sec
      end
    end

    defp timeout_sec(_value), do: @default_timeout_sec

    defp normalize_keys(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  defmodule Result do
    @moduledoc """
    One command's outcome.

    `cwd` is where the shell actually ended up rather than where it was
    asked to start, so the next command in the dock carries on from there.
    `timed_out` is the 124 the timeout wrapper exits with, told apart from a
    command that chose to exit 124 only in that nothing else does.
    """

    @enforce_keys [:stdout, :stderr, :code, :cwd, :timed_out, :duration_ms]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            stdout: String.t(),
            stderr: String.t(),
            code: non_neg_integer(),
            cwd: String.t(),
            timed_out: boolean(),
            duration_ms: non_neg_integer()
          }
  end

  defmodule Status do
    @moduledoc """
    Whether the terminal will work, asked before the panel renders a prompt
    that cannot. `cwd` is offered either way, because the dock shows where a
    command *would* run even when it currently cannot run one.
    """

    @enforce_keys [:available, :why, :cwd]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            available: boolean(),
            why: Ravix.Vitals.unreachable() | nil,
            cwd: String.t()
          }
  end

  @typedoc """
  Everything an exec call can refuse with, and nothing else.

  Notably not `{:unconfigured, :sprites}`: a deployment with no Sprites token
  is turned into the `no_exec` sentence here, because "the terminal is not
  available on this Ravix" is a thing the panel can say and the generic
  sentence for a missing provider is not.
  """
  @type reason ::
          :not_found
          | {:conflict, String.t(), String.t()}
          | {:unprocessable, String.t(), String.t()}
          | {:unavailable, String.t(), String.t()}
          | Ravix.Sprites.Error.t()

  @no_exec "This Ravix deployment has no machine connection configured, so it cannot run commands on the machine directly."
  @no_sprite "This machine does not expose a sprite, so Ravix cannot run commands on it directly."

  @doc """
  Run one command in the track's worktree.

  `request` is a `Ravix.Terminal.Request`, or anything it can be parsed
  from: `command`, `cwd` (pinned under the workdir; the page sends back
  where the last command ended so `cd` is remembered by the one thing that
  can remember it) and `timeout_sec`. A sandbox on a provider that is not
  Sprites is a real and reportable state rather than a failure: exec is not
  "broken", it does not apply.

  The request is parsed *inside* the `with`, after access. An empty command
  is a refusal, and refusing it before establishing who is asking would
  answer a stranger's guess at a track id with "Type a command" instead of
  "not found".
  """
  @spec exec(User.t(), String.t(), Request.t() | map()) ::
          {:ok, Result.t()} | {:error, reason()}
  def exec(%User{} = user, track_id, request) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id, :write),
         {:ok, sprites} <- sprites(),
         {:ok, %Request{} = request} <- Request.parse(request),
         {:ok, sprite} <- sprite_of(project, track) do
      cwd = Sprites.resolve_cwd(track.workdir, request.cwd)
      started = System.monotonic_time(:millisecond)

      case Sprites.shell(sprites, sprite, request.command, cwd, request.timeout_sec) do
        {:ok, ran, ended_in} ->
          {:ok,
           %Result{
             stdout: ran.stdout,
             stderr: ran.stderr,
             code: ran.code,
             # Where the shell actually ended up, so the next command starts
             # there --- pinned back under the track's directory, because the
             # box decides where it went and this decides where it may be.
             cwd: Sprites.resolve_cwd(track.workdir, ended_in),
             timed_out: ran.code == 124,
             duration_ms: System.monotonic_time(:millisecond) - started
           }}

        {:error, {:unconfigured, :sprites}} ->
          {:error, {:unavailable, "no_exec", @no_exec}}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Whether the terminal will work. A passive read of the machine's runtime
  state: it runs nothing, so it never wakes a parked machine
  (`Ravix.Tracks.wake/2` does that, through Fountain).

  Three distinct answers, and the panel renders a different empty state for
  each: no token on this deployment, no machine yet, or a machine that is
  asleep or unreachable. Collapsing them into one "unavailable" is how
  people end up filing a bug about a feature that is off by configuration.
  """
  @spec status(User.t(), String.t()) :: {:ok, Status.t()} | {:error, :not_found}
  def status(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id) do
      {:ok, status_of(Sprites.config(), track, project)}
    end
  end

  defp status_of(nil, track, _project),
    do: %Status{available: false, why: :no_token, cwd: track.workdir}

  defp status_of(sprites, track, project) do
    case sprite_of(project, track) do
      {:ok, sprite} ->
        if Sprites.running?(sprites, sprite) do
          woke(track)
          %Status{available: true, why: nil, cwd: track.workdir}
        else
          %Status{available: false, why: :unreachable, cwd: track.workdir}
        end

      {:error, {:conflict, "no_machine", _}} ->
        %Status{available: false, why: :no_machine, cwd: track.workdir}

      {:error, _} ->
        %Status{available: false, why: :no_sprite, cwd: track.workdir}
    end
  end

  # A running machine is not asleep, whatever the stream last said. Only a
  # row that says otherwise is written, so a probe of an awake one is free.
  defp woke(%{sandbox_layout: :dedicated, sandbox_suspended_at: %DateTime{}} = track),
    # ownership: Access.track_access in status/3 admitted this track.
    do: Sleep.record(track.id, false)

  defp woke(_track), do: :ok

  # The machine, then the sprite behind it: the two answers the panels tell apart.
  defp sprite_of(project, track) do
    case Tracks.machine_of_track(project, track) do
      {:ok, %{sandbox_id: sandbox_id}} ->
        case Tracks.sprite_for(sandbox_id) do
          nil -> {:error, {:unavailable, "no_exec", @no_sprite}}
          sprite -> {:ok, sprite}
        end

      _ ->
        {:error,
         {:conflict, "no_machine", "This project has no machine yet. Open a track first."}}
    end
  end

  defp sprites do
    case Ravix.Providers.sprites() do
      {:ok, config} -> {:ok, config}
      {:error, {:unconfigured, :sprites}} -> {:error, {:unavailable, "no_exec", @no_exec}}
    end
  end

  # ── interactive terminals ────────────────────────────────────────────

  @doc "How many terminal tabs one person may have open on one track."
  @spec max_tabs() :: pos_integer()
  def max_tabs, do: @max_tabs

  @doc """
  This person's terminal tabs on a track, oldest number first.

  Nobody else's: two people on one track each have their own terminals on
  the same machine.
  """
  @spec tabs(User.t(), String.t()) :: {:ok, [Tab.t()]} | {:error, :not_found}
  def tabs(%User{} = user, track_id) do
    with {:ok, _access} <- open_track(user, track_id, :read) do
      # ownership: open_track/2 (Access.track_access) admitted this person to this track.
      {:ok, Store.list(track_id, user.id)}
    end
  end

  @doc """
  A new terminal tab, on the machine the track's worktree is on.

  Only the row: the shell starts when a page attaches to it, at the size the
  page measured. Refused when this deployment cannot reach machines, when
  there is no machine yet, and past `max_tabs/0`.
  """
  @spec open_tab(User.t(), String.t()) :: {:ok, Tab.t()} | {:error, reason()}
  def open_tab(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- open_track(user, track_id),
         {:ok, _sprites} <- sprites(),
         :ok <- room(track.id, user.id),
         {:ok, sprite} <- sprite_of(project, track) do
      # ownership: open_track/2 (Access.track_access) admitted this person to this track.
      case Store.insert(track.id, user.id, sprite) do
        {:ok, tab} -> {:ok, tab}
        {:error, _} -> {:error, {:conflict, "terminal_busy", "Try opening the terminal again."}}
      end
    end
  end

  defp room(track_id, user_id) do
    # ownership: open_tab/2 established access through open_track/2 first.
    if Store.count(track_id, user_id) < @max_tabs,
      do: :ok,
      else:
        {:error,
         {:conflict, "terminal_limit",
          "Close a terminal first: a track can have #{@max_tabs} open at once."}}
  end

  @doc """
  Attach the calling process (the page) to one of this person's tabs.

  Starts a `Ravix.Terminal.Shell` that starts the tab's shell, or re-attaches
  to it if it is already running, and sends the page `{:terminal, tab_id,
  event}` messages; see that module. `session_hash` is the page's session,
  which the shell watches so that signing out, or the session running out,
  ends the terminal at once rather than on the page's next message.

  `size` is `%{cols: _, rows: _}` as the browser measured it. Attaching a
  tab the page already has attached answers the same shell.
  """
  @spec attach(User.t(), String.t() | nil, String.t(), String.t(), map()) ::
          {:ok, pid()} | {:error, reason()}
  def attach(%User{} = user, session_hash, track_id, tab_id, size \\ %{}) do
    with {:ok, %{track: track, project: project}} <- open_track(user, track_id),
         {:ok, expires_at} <- session_of(user, session_hash),
         {:ok, cfg} <- sprites(),
         # ownership: open_track/2 (Access.track_access) admitted this person to this track.
         %Tab{} = tab <- Store.get(track.id, user.id, tab_id) || {:error, :not_found} do
      %{cols: cols, rows: rows} = size(size)

      Ravix.Terminal.Supervisor
      |> DynamicSupervisor.start_child(
        {Shell,
         %{
           cfg: cfg,
           tab: tab,
           user: user,
           project_id: project.id,
           session_hash: session_hash,
           expires_at: expires_at,
           owner: self(),
           callers: [self() | Process.get(:"$callers", [])],
           dir: Sprites.resolve_cwd(track.workdir, nil),
           cols: cols,
           rows: rows
         }}
      )
      |> case do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end
  end

  @doc """
  Bytes typed into the calling page's terminal `tab_id`.

  Only the page that attached it can reach it --- the shell is registered
  under the page's own pid --- so this asks nothing: the shell watches the
  session and the track itself. A tab that is not attached drops the bytes.
  """
  @spec input(String.t(), binary()) :: :ok
  def input(tab_id, data) when is_binary(tab_id) and is_binary(data),
    do: Shell.input(self(), tab_id, data)

  @doc "The calling page's terminal `tab_id` has a new size; nonsense sizes are ignored."
  @spec resize(String.t(), term(), term()) :: :ok
  def resize(tab_id, cols, rows) when is_binary(tab_id) do
    case size(%{cols: cols, rows: rows}) do
      %{cols: ^cols, rows: ^rows} -> Shell.resize(self(), tab_id, cols, rows)
      _clamped_or_default -> :ok
    end
  end

  @doc "Let the calling page's terminal `tab_id` go, without ending its shell."
  @spec detach(String.t()) :: :ok
  def detach(tab_id) when is_binary(tab_id), do: Shell.detach(self(), tab_id)

  @doc """
  Close one of this person's tabs: its shell is ended on the machine and the
  tab is forgotten. A page still attached hears `{:exited, _}` or nothing,
  and should stop showing it either way.
  """
  @spec close_tab(User.t(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def close_tab(%User{} = user, track_id, tab_id) do
    with {:ok, _access} <- open_track(user, track_id, :read),
         # ownership: open_track/2 (Access.track_access) admitted this person to this track.
         %Tab{} = tab <- Store.get(track_id, user.id, tab_id) || {:error, :not_found} do
      if tab.session_id, do: Pty.kill(Sprites.config(), tab.sprite, tab.session_id)
      Store.delete(tab.id, user.id)
      :ok
    end
  end

  # A terminal is on a track somebody may still work in: access, and not
  # closed, which is the same thing `RavixWeb.TrackLive` asks of its page.
  # A shell can do anything a command can, so opening or attaching one needs
  # Write (ADR 0010), as `exec/3` does; listing and closing your own tabs
  # only needs to see the track, so a person demoted to Read can clean up.
  defp open_track(user, track_id, need \\ :write) do
    case Access.track_access(user, track_id, need) do
      {:ok, %{track: %{closed_at: nil}} = access} -> {:ok, access}
      _ -> {:error, :not_found}
    end
  end

  defp session_of(%User{id: id}, hash) when is_binary(hash) do
    case Accounts.open_session(hash) do
      {:ok, %User{id: ^id}, expires_at} -> {:ok, expires_at}
      _ -> {:error, :not_found}
    end
  end

  defp session_of(_user, _hash), do: {:error, :not_found}

  # A terminal smaller than this is not usable and larger is not a screen;
  # both come from a browser that measured a hidden element.
  defp size(%{cols: cols, rows: rows})
       when is_integer(cols) and is_integer(rows) and cols in 2..1000 and rows in 2..500,
       do: %{cols: cols, rows: rows}

  defp size(_other), do: @default_size
end
