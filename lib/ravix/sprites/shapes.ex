defmodule Ravix.Sprites.Shapes do
  @moduledoc """
  The shape Sprites describes a managed service in, and the one Ravix reads.

  The other half of the boundary `Ravix.Fountain.Shapes` and
  `Ravix.GitHub.Shapes` are: a service arrived as
  `%{optional(String.t()) => term()}` and was read by string key and by
  `get_in/2` string path in `Ravix.Previews.Server`, which is the only module
  that reads one at all.

  Two of those reads were the same question written twice --
  `get_in(service, ["state", "status"]) != "running"` in `define/4` and
  `get_in(actual, ["state", "status")] == "running"` in `running?/1` -- and a
  third, `restart_count`, reached two levels into a map for a number it then
  defaulted with `|| 0`. A `nil` from any of them is indistinguishable from
  Sprites answering "not running", which for `restart_count` means a crash
  loop reads as a healthy service.

  ## What is here and what is not

  `Service` carries the fields the preview startup actually decides on: the
  definition it compares against what it asked for (`cmd`, `args`, `dir`,
  `env`, `http_port`, `needs`), and the `state` it polls (`status`,
  `restart_count`). `running?/1` and `crash_looping?/1` are the two questions
  asked of the state.

  `env` stays a plain string-keyed map. It is Sprites' copy of a process
  environment -- an open set of names Ravix writes two of and reads the same
  two back -- not a record with fields, and closing it would mean inventing a
  struct for every variable a startup command might want.

  `status` is left as the string Sprites sent rather than mapped to atoms.
  Ravix asks exactly one thing of it, `running?/1`; the rest of the
  vocabulary is Sprites' own, open, and reported rather than branched on.
  This is the same line `Ravix.Tracks.Transcript.Event` draws between `kind`,
  which it matches on and closes, and `stage`, which it does not.
  """

  defmodule Exec do
    @moduledoc """
    What one command produced: the two streams, kept apart, and its exit code.

    Sprites answers an exec with a frame stream rather than plain bytes ---
    `<id byte><payload up to the next byte < 4>`, with a two-byte exit frame
    --- which is how stdout and stderr stay separate and how the code
    arrives at all. `Ravix.Sprites.decode_frames/1` is the one place that is
    read, and this is what it reads into.

    It was two map types: `raw_exec` for `exec/4` and `shell_exec`, which
    was `raw_exec` written out again with `cwd` on the end. There is one
    shape here, not two. The directory a shell ended in is not part of what
    a command produced --- it is a second answer, printed by the wrapper on
    its own line and cut back out of stdout --- so `Ravix.Sprites.shell/5`
    returns it beside this rather than inside it, the way
    `Ravix.Accounts.open_session/1` answers `{:ok, user, expires_at}`.

    A missing exit frame reads as `code: 0`. A truncated response is not the
    same as a failing command, and reporting a non-zero code for one would
    put a red exit line under working output.
    """

    @enforce_keys [:stdout, :stderr, :code]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            stdout: String.t(),
            stderr: String.t(),
            code: non_neg_integer()
          }
  end

  defmodule Service do
    @moduledoc "A managed service, as `GET /v1/services/:name` describes it."

    @enforce_keys [:name, :cmd, :args, :dir, :env, :http_port, :needs, :status, :restart_count]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            name: String.t() | nil,
            cmd: String.t() | nil,
            args: [String.t()],
            dir: String.t() | nil,
            env: %{optional(String.t()) => String.t()},
            http_port: term(),
            needs: [term()],
            status: String.t() | nil,
            restart_count: integer()
          }
  end

  @doc """
  One service, from the JSON Sprites sent.

  `restart_count` defaults to zero here rather than at each reader, and
  `args` and `needs` to empty lists, so a comparison against what Ravix
  asked for is against a list either way.

  A service Sprites has no definition for is not this -- it is `nil`, which
  `Ravix.Sprites.service/3` answers with and `running?/1`, `crash_looping?/1`
  and `defined_as?/4` all accept.
  """
  @spec service(map()) :: Service.t()
  def service(raw) when is_map(raw) do
    state = if is_map(raw["state"]), do: raw["state"], else: %{}

    %Service{
      name: raw["name"],
      cmd: raw["cmd"],
      args: list(raw["args"]),
      dir: raw["dir"],
      env: if(is_map(raw["env"]), do: raw["env"], else: %{}),
      http_port: raw["http_port"],
      needs: list(raw["needs"]),
      status: state["status"],
      restart_count: if(is_integer(state["restart_count"]), do: state["restart_count"], else: 0)
    }
  end

  @doc """
  The service is up. The one thing Ravix asks of Sprites' status vocabulary.

  `nil` is a service Sprites has no definition for, which `Ravix.Sprites`
  answers `{:ok, nil}` to. It is not running, and saying so here is what lets
  the readiness loop keep polling a service that is still being created
  rather than crash on the gap between allocating a port and defining it.
  """
  @spec running?(Service.t() | nil) :: boolean()
  def running?(nil), do: false
  def running?(%Service{status: status}), do: status == "running"

  @doc """
  The service has restarted enough times to call it broken rather than slow.

  Three. A preview whose command exits immediately would otherwise be
  restarted by Sprites for the whole startup deadline and then reported as
  "not ready in time", which sends the reader to the logs for a timeout that
  was really a crash on the first line.
  """
  @spec crash_looping?(Service.t() | nil) :: boolean()
  def crash_looping?(nil), do: false
  def crash_looping?(%Service{restart_count: count}), do: count >= 3

  @doc """
  The service is defined exactly as `Ravix.Sprites.define_service/6` asks for.

  Anything else -- a different command, a moved directory, a port that is not
  the one allocated, an `http_port` that would put the preview on the
  machine's public route -- means the definition on the machine is not this
  track's and has to be replaced rather than started.
  """
  @spec defined_as?(Service.t() | nil, String.t(), String.t(), pos_integer()) :: boolean()
  def defined_as?(nil, _command, _directory, _port), do: false

  def defined_as?(%Service{} = service, command, directory, port) do
    service.cmd == "sh" and service.args == ["-lc", command] and
      service.dir == directory and
      service.env["PORT"] == Integer.to_string(port) and
      service.env["HOST"] == "127.0.0.1" and
      service.http_port == nil and
      service.needs == []
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
