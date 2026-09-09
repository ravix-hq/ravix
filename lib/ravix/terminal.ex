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

  # The ceiling on one command, in seconds. A build is fine; a server is not.
  @max_timeout_sec 120
  @default_timeout_sec 60
  @max_command_chars 8_000

  @typedoc "One command's outcome, the `ExecResult` of `shared/api.ts`."
  @type result :: %{
          stdout: String.t(),
          stderr: String.t(),
          code: non_neg_integer(),
          cwd: String.t(),
          timed_out: boolean(),
          duration_ms: non_neg_integer()
        }

  @typedoc "Whether the terminal will work, before the panel renders a prompt that cannot."
  @type status :: %{available: boolean(), why: Ravix.Vitals.unreachable() | nil, cwd: String.t()}

  @type reason ::
          :not_found
          | {:conflict, String.t(), String.t()}
          | {:unprocessable, String.t(), String.t()}
          | {:unavailable, String.t(), String.t()}
          | Ravix.Sprites.Error.t()
          | term()

  @no_exec "This Ravix deployment has no Sprites token, so it cannot run commands on the machine directly."
  @no_sprite "This machine does not expose a sprite, so Ravix cannot run commands on it directly."

  @doc """
  `POST /api/tracks/:id/exec`: run one command in the track's worktree.

  `request` (string or atom keys): `command` (at most 8000 characters),
  `cwd` (pinned under the workdir; the page sends back where the last
  command ended so `cd` is remembered by the one thing that can remember
  it) and `timeout_sec` (1 to 120, default 60). A sandbox on a provider
  that is not Sprites is a real and reportable state rather than a failure:
  exec is not "broken", it does not apply.
  """
  @spec exec(User.t(), String.t(), map()) :: {:ok, result()} | {:error, reason()}
  def exec(%User{} = user, track_id, request) do
    request = stringify(request)
    command = request["command"] |> text(@max_command_chars)

    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id),
         {:ok, sprites} <- sprites(),
         :ok <-
           if(command == "",
             do: {:error, {:unprocessable, "empty_command", "Type a command."}},
             else: :ok
           ),
         {:ok, sprite} <- sprite_of(project) do
      cwd = Sprites.resolve_cwd(track.workdir, request["cwd"])
      timeout = request["timeout_sec"] |> timeout_sec()
      started = System.monotonic_time(:millisecond)

      case Sprites.shell(sprites, sprite, command, cwd, timeout) do
        {:ok, r} ->
          {:ok,
           %{
             stdout: r.stdout,
             stderr: r.stderr,
             code: r.code,
             # Where the shell actually ended up, so the next command starts there.
             cwd: Sprites.resolve_cwd(track.workdir, r.cwd),
             timed_out: r.code == 124,
             duration_ms: System.monotonic_time(:millisecond) - started
           }}

        {:error, :unconfigured} ->
          {:error, {:unavailable, "no_exec", @no_exec}}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  `GET /api/tracks/:id/exec`: whether the terminal will work.

  Three distinct answers, and the panel renders a different empty state for
  each: no token on this deployment, no machine yet, or a machine that is
  asleep or unreachable. Collapsing them into one "unavailable" is how
  people end up filing a bug about a feature that is off by configuration.
  """
  @spec status(User.t(), String.t()) :: {:ok, status()} | {:error, :not_found}
  def status(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id) do
      {:ok, status_of(Sprites.config(), track, project)}
    end
  end

  defp status_of(nil, track, _project),
    do: %{available: false, why: :no_token, cwd: track.workdir}

  defp status_of(sprites, track, project) do
    case sprite_of(project) do
      {:ok, sprite} ->
        if Sprites.reachable?(sprites, sprite),
          do: %{available: true, why: nil, cwd: track.workdir},
          else: %{available: false, why: :unreachable, cwd: track.workdir}

      {:error, {:conflict, "no_machine", _}} ->
        %{available: false, why: :no_machine, cwd: track.workdir}

      {:error, _} ->
        %{available: false, why: :no_sprite, cwd: track.workdir}
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
    case Sprites.config() do
      nil -> {:error, {:unavailable, "no_exec", @no_exec}}
      config -> {:ok, config}
    end
  end

  defp timeout_sec(value) when is_integer(value), do: value |> max(1) |> min(@max_timeout_sec)

  defp timeout_sec(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> timeout_sec(n)
      _ -> @default_timeout_sec
    end
  end

  defp timeout_sec(_), do: @default_timeout_sec

  defp text(value, max) when is_binary(value), do: value |> String.slice(0, max) |> String.trim()
  defp text(_value, _max), do: ""

  defp stringify(attrs) when is_map(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}
end
