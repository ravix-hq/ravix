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
  """

  alias Ravix.Accounts.Access
  alias Ravix.Accounts.User
  alias Ravix.Sprites
  alias Ravix.Tracks

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

  @no_exec "This Ravix deployment has no Sprites token, so it cannot run commands on the machine directly."
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
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id),
         {:ok, sprites} <- sprites(),
         {:ok, %Request{} = request} <- Request.parse(request),
         {:ok, sprite} <- sprite_of(project) do
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
  Whether the terminal will work.

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
    case sprite_of(project) do
      {:ok, sprite} ->
        if Sprites.reachable?(sprites, sprite),
          do: %Status{available: true, why: nil, cwd: track.workdir},
          else: %Status{available: false, why: :unreachable, cwd: track.workdir}

      {:error, {:conflict, "no_machine", _}} ->
        %Status{available: false, why: :no_machine, cwd: track.workdir}

      {:error, _} ->
        %Status{available: false, why: :no_sprite, cwd: track.workdir}
    end
  end

  # The machine, then the sprite behind it: the two answers the panels tell apart.
  defp sprite_of(project) do
    case Tracks.machine_of(project) do
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
end
