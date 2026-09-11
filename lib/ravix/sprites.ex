defmodule Ravix.Sprites do
  @moduledoc """
  Running a command on the machine.

  Fountain deliberately has no exec: reads of a sandbox are free, and every
  *write* to the box is a turn taken by the agent that lives on it. That is
  the right boundary for Fountain and it is why paddock's terminal is a
  Claude Code prompt rendered as scrollback rather than a shell.

  Ravix goes one layer down. Fountain's sandboxes run on Sprites, and a
  sandbox tells you the name of its sprite (`sandbox.sprite_name`), so a
  server holding a Sprites token can talk to the same machine directly. That
  buys the two panels an agent conversation genuinely cannot give you: a
  terminal, and a run command whose output you watch.

  Three things about this are worth being clear-eyed about, and the UI says
  all three rather than leaving them to be discovered:

    1. **It is optional.** No `SPRITES_TOKEN`, no terminal, and ravix still
       works completely, because everything else goes through Fountain. The
       panels render a designed empty state naming the missing variable. In
       code that is a `nil` config, and every function here answers
       `{:error, :unconfigured}` to one.
    2. **It is not a PTY.** Sprites' exec is one HTTP request in, a
       multiplexed byte stream out, and then it is over. `ls`, `git status`
       and `npm test` are exactly right. `vim` and `top` are not, and the
       panel says so where somebody would type them.
    3. **It is out of band.** These commands do not go through Fountain, so
       they are not turns, they do not appear in the transcript, and they do
       not wait for the box's one-turn-at-a-time lock. That is the feature
       (you can look around while the agent is working) and also the risk,
       which is why exec is confined to a track's own worktree by
       `resolve_cwd/2` below rather than by asking nicely.

  Every function takes the config first, the map `Ravix.Config.sprites/0`
  returns, so a test can pass its own. HTTP goes through `Req`, and whatever
  is under `Application.get_env(:ravix, :req_options)` is merged into every
  request; the test environment puts `plug: {Req.Test, Ravix.Sprites}` there.
  """

  alias Ravix.Sprites.Error
  alias Ravix.Sprites.Shapes

  # Sprites' exec frames its output: 1 = stdout, 2 = stderr, 3 = exit code.
  @frame_stdout 1
  @frame_stderr 2
  @frame_exit 3

  # Service operations and logs are bounded to the last 32,000 bytes.
  @tail 32_000
  @service_timeout 25_000
  @cwd_marker "__ravix_cwd__"

  @typedoc """
  The Sprites API token and base URL, or nil when there is none.

  `Ravix.Config.Sprites`, which redacts the token from `Inspect`; every
  function here takes one as its first argument, so it travels widely.
  """
  @type config :: Ravix.Config.Sprites.t() | nil

  @typedoc "A managed service as Sprites describes it. See `Ravix.Sprites.Shapes`."
  @type service :: Shapes.Service.t()

  @typedoc "What one exec produced. See `Ravix.Sprites.Shapes.Exec`."
  @type exec :: Shapes.Exec.t()

  @typedoc """
  Which way an activity lease is being moved: taken and renewed, or dropped.
  """
  @type lease :: :hold | :release

  @type error :: Error.t() | :unconfigured

  @doc "The configured client, or nil without a `SPRITES_TOKEN`."
  @spec config() :: config()
  def config, do: Ravix.Config.sprites()

  @doc "One managed service, or nil when Sprites has no service by that name."
  @spec service(config(), String.t(), String.t()) :: {:ok, service() | nil} | {:error, error()}
  def service(nil, _sprite, _name), do: {:error, :unconfigured}

  def service(cfg, sprite, name) do
    case service_request(cfg, sprite, name, :get, nil, missing_ok: true) do
      {:ok, %{status: 404}} -> {:ok, nil}
      {:ok, %{body: body}} -> decode_service(body)
      {:error, _} = error -> error
    end
  end

  @doc """
  Define (or redefine) a service that runs `command` in `directory` on `port`.

  No `http_port`: the machine-wide public route must never expose a preview.
  The service gets `PORT` and `HOST=127.0.0.1` in its environment and is
  reachable only through the tunnel. Returns the tail of Sprites' NDJSON
  progress output.
  """
  @spec define_service(config(), String.t(), String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, error()}
  def define_service(nil, _sprite, _name, _directory, _command, _port),
    do: {:error, :unconfigured}

  def define_service(cfg, sprite, name, directory, command, port) do
    body = %{
      cmd: "sh",
      args: ["-lc", command],
      dir: directory,
      env: %{PORT: Integer.to_string(port), HOST: "127.0.0.1"},
      needs: []
    }

    with {:ok, resp} <- service_request(cfg, sprite, "#{name}?duration=1s", :put, body) do
      {:ok, tail(resp.body)}
    end
  end

  @doc """
  Start, stop or delete a service. Returns the tail of Sprites' output.

  Stopping is idempotent: a service that already exited answers with a
  specific 409 conflict, which is treated as success, while every other
  conflict (including a start conflict) is still an error to surface and
  retry. Stopping or deleting a service that does not exist is not an error.
  """
  @spec service_action(config(), String.t(), String.t(), :start | :stop | :delete) ::
          {:ok, String.t()} | {:error, error()}
  def service_action(nil, _sprite, _name, _action), do: {:error, :unconfigured}

  def service_action(cfg, sprite, name, action) when action in [:start, :stop, :delete] do
    {path, method} =
      case action do
        :delete -> {name, :delete}
        other -> {"#{name}/#{other}?duration=1s", :post}
      end

    opts = [missing_ok: action != :start, stopped_ok: action == :stop]

    with {:ok, resp} <- service_request(cfg, sprite, path, method, nil, opts) do
      {:ok, tail(resp.body)}
    end
  end

  @doc "The last 32,000 bytes of a service's log, stdout and stderr together."
  @spec service_logs(config(), String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def service_logs(cfg, sprite, name) do
    argv = ["tail", "-c", Integer.to_string(@tail), "/.sprite/logs/services/#{name}.log"]

    with {:ok, result} <- exec(cfg, sprite, argv, 15) do
      {:ok, tail(result.stdout <> result.stderr)}
    end
  end

  @doc """
  Hold or release the activity lease that keeps a preview's machine awake.

  The lease is a Sprites task named after the service that expires two
  minutes after the last touch, taken over the machine's local API socket.
  A Sprite whose API has no expiring tasks answers the PUT with a failure,
  which comes back as a 501 so the preview can say the feature is missing
  rather than retrying forever.
  """
  @spec activity(config(), String.t(), String.t(), lease()) :: :ok | {:error, error()}
  def activity(cfg, sprite, name, lease \\ :hold) when lease in [:hold, :release] do
    argv =
      [
        "curl",
        "--fail-with-body",
        "--silent",
        "--show-error",
        "--unix-socket",
        "/.sprite/api.sock",
        "-X",
        if(lease == :release, do: "DELETE", else: "PUT"),
        "http://sprite/v1/tasks/#{name}"
      ] ++
        if(lease == :release,
          do: [],
          else: ["-H", "Content-Type: application/json", "-d", ~s({"expire":"2m"})]
        )

    case exec(cfg, sprite, argv, 15) do
      {:ok, %{code: code}} when code != 0 and lease == :hold ->
        {:error, Error.new(501, "This Sprite does not support expiring preview activity tasks.")}

      {:ok, _} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  One command, as an argv, on one sprite.

  The response body is a stream of frames rather than plain bytes, which is
  how stdout and stderr stay separate and how the exit code arrives at all.
  A frame is `<id byte><payload up to the next byte < 4>`; the exit frame is
  two bytes. Reading it is a dozen lines and the alternative (one merged
  stream with the exit code printed at the end) loses the distinction the
  terminal panel renders in a different colour.

  `timeout_sec` is the command's own budget; the HTTP request waits fifteen
  seconds longer than that before giving up on the machine.
  """
  @spec exec(config(), String.t(), [String.t()], pos_integer()) ::
          {:ok, exec()} | {:error, error()}
  def exec(nil, _sprite, _argv, _timeout_sec), do: {:error, :unconfigured}

  def exec(cfg, sprite, argv, timeout_sec) when is_list(argv) do
    query = URI.encode_query(Enum.map(argv, &{"cmd", &1}))
    url = "#{cfg.base_url}/v1/sprites/#{encode(sprite)}/exec?#{query}"

    request =
      new_request(cfg,
        method: :post,
        url: url,
        headers: [{"content-type", "application/octet-stream"}],
        receive_timeout: timeout_sec * 1000 + 15_000
      )

    case Req.request(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, decode_frames(body)}

      {:ok, %{status: 404}} ->
        {:error,
         Error.new(
           404,
           "This machine is not reachable over Sprites. It may be asleep, or built somewhere this token cannot see."
         )}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.new(status, String.trim("Sprites said #{status}. #{detail(body)}"))}

      {:error, reason} ->
        {:error, transport_error(reason)}
    end
  end

  @doc """
  A shell command, and, beside it, the directory it ended in.

  The command runs under `sh -c` in `cwd`, and then the wrapper prints where
  it ended up on its own line. That last part is what makes the terminal
  feel like a terminal: `cd ..` has to be remembered by *something*, and
  since each exec is a fresh process, the something is this line and the
  cwd the client sends back with the next command.

  Two answers, so two values. The directory is not something the command
  produced; it is a line the wrapper printed, which this cuts back out of
  stdout. It used to be a fourth key on a copy of the exec type, which is
  what made the two types look like two shapes.

  The marker is a random-looking sentinel rather than a newline convention
  because a command's own output is arbitrary and will eventually contain
  whatever separator you picked.
  """
  @spec shell(config(), String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, exec(), String.t()} | {:error, error()}
  def shell(cfg, sprite, command, cwd, timeout_sec) do
    script =
      "cd #{shq(cwd)} 2>/dev/null || cd /home/sprite; { #{command}\n }; __rc=$?; " <>
        "printf '\\n#{@cwd_marker}%s\\n' \"$PWD\"; exit $__rc"

    with {:ok, raw} <- exec(cfg, sprite, ["sh", "-lc", script], timeout_sec) do
      {ran, ended_in} = split_cwd(raw, cwd)
      {:ok, ran, ended_in}
    end
  end

  @doc "Is this sprite reachable at all? Used to decide between two empty states."
  @spec reachable?(config(), String.t()) :: boolean()
  def reachable?(cfg, sprite), do: match?({:ok, %{code: 0}}, exec(cfg, sprite, ["true"], 15))

  @doc """
  Where a command is allowed to run.

  A track owns one directory and the terminal panel belongs to a track, so the
  server pins `cwd` under that directory rather than trusting the client's.
  The browser sends where it thinks it is; this decides. Without it the
  terminal is a way to walk out of the worktree the whole app is built to keep
  work inside of; the one rule the agent is told three times to follow would
  be undone by a text box beneath it.

  Escaping upward is not an error the user needs a lecture about: it snaps
  back to the root and the panel shows where it actually is.
  """
  @spec resolve_cwd(String.t(), String.t() | nil) :: String.t()
  def resolve_cwd(root, requested) when requested in [nil, ""], do: root

  def resolve_cwd(root, requested) do
    absolute = if String.starts_with?(requested, "/"), do: requested, else: "#{root}/#{requested}"
    normalized = normalize_posix(absolute)
    root_norm = normalize_posix(root)

    if normalized == root_norm or String.starts_with?(normalized, root_norm <> "/"),
      do: normalized,
      else: root_norm
  end

  @doc "Single-quote for `sh`, the only quoting that is safe for arbitrary bytes."
  @spec shq(String.t()) :: String.t()
  def shq(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  @doc """
  The frame decoder, public so the tests can prove it against real bytes.

  A missing exit frame reads as success: a truncated response is not the
  same as a failing command, and reporting a non-zero code for one would put
  a red exit line under working output.
  """
  @spec decode_frames(binary()) :: exec()
  def decode_frames(raw) when is_binary(raw), do: decode_frames(raw, [], [], 0)

  defp decode_frames(<<>>, out, err, code) do
    %Shapes.Exec{stdout: finish(out), stderr: finish(err), code: code}
  end

  defp decode_frames(<<@frame_exit, code, rest::binary>>, out, err, _code),
    do: decode_frames(rest, out, err, code)

  defp decode_frames(<<@frame_exit>>, out, err, _code), do: decode_frames(<<>>, out, err, 0)

  defp decode_frames(<<id, rest::binary>>, out, err, code) do
    length = payload_length(rest, 0)
    <<payload::binary-size(length), rest::binary>> = rest

    case id do
      @frame_stdout -> decode_frames(rest, [payload | out], err, code)
      @frame_stderr -> decode_frames(rest, out, [payload | err], code)
      _other -> decode_frames(rest, out, err, code)
    end
  end

  defp payload_length(<<byte, rest::binary>>, n) when byte >= 4, do: payload_length(rest, n + 1)
  defp payload_length(_rest, n), do: n

  defp finish(parts), do: parts |> Enum.reverse() |> IO.iodata_to_binary() |> utf8()

  # Output is rendered and sent over a JSON socket, so it has to be UTF-8.
  # Invalid bytes become U+FFFD the way TextDecoder did it.
  defp utf8(binary) do
    if String.valid?(binary), do: binary, else: scrub(binary, [])
  end

  defp scrub(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp scrub(<<cp::utf8, rest::binary>>, acc), do: scrub(rest, [<<cp::utf8>> | acc])
  defp scrub(<<_byte, rest::binary>>, acc), do: scrub(rest, ["�" | acc])

  # ── the service API ──────────────────────────────────────────────────

  defp service_request(cfg, sprite, path, method, body, opts \\ []) do
    missing_ok = Keyword.get(opts, :missing_ok, false)
    stopped_ok = Keyword.get(opts, :stopped_ok, false)

    request =
      new_request(cfg,
        method: method,
        url: "#{cfg.base_url}/v1/sprites/#{encode(sprite)}/services/#{path}",
        headers: [{"content-type", "application/json"}],
        body: if(body, do: Jason.encode!(body)),
        receive_timeout: @service_timeout
      )

    case Req.request(request) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, resp}

      {:ok, %{status: 404} = resp} when missing_ok ->
        {:ok, resp}

      {:ok, %{status: 409, body: body}} when stopped_ok and is_binary(body) ->
        # A stopped process may be reported as failed (SIGTERM/exit 143).
        # Sprites answers a repeated stop with this specific conflict instead
        # of 2xx. Its desired outcome is already satisfied; other conflicts,
        # including start conflicts, must still be surfaced and retried.
        if String.trim(body) == "service is not running",
          do: {:ok, %Req.Response{status: 204, body: ""}},
          else: {:error, service_error(409)}

      {:ok, %{status: status}} ->
        {:error, service_error(status)}

      {:error, reason} ->
        {:error, transport_error(reason)}
    end
  end

  defp service_error(status) do
    Error.new(
      status,
      "Sprites service operation failed (#{status}). Check service support and the deployment token."
    )
  end

  defp decode_service(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = service} ->
        {:ok, Shapes.service(service)}

      _ ->
        {:error,
         Error.new(502, "Sprites described the service in a shape this server cannot read.")}
    end
  end

  defp decode_service(%{} = service), do: {:ok, Shapes.service(service)}

  defp decode_service(_other),
    do:
      {:error,
       Error.new(502, "Sprites described the service in a shape this server cannot read.")}

  defp transport_error(%Req.TransportError{reason: :timeout}),
    do: Error.new(502, "The machine did not answer in time.")

  defp transport_error(_reason), do: Error.new(502, "Could not reach the machine.")

  defp new_request(cfg, options) do
    defaults = [auth: {:bearer, cfg.token}, retry: false, decode_body: false]

    defaults
    |> Keyword.merge(options)
    |> Keyword.merge(Application.get_env(:ravix, :req_options, []))
    |> Req.new()
  end

  defp detail(body) when is_binary(body),
    do: body |> binary_part(0, min(byte_size(body), 200)) |> utf8()

  defp detail(_body), do: ""

  # encodeURIComponent: everything but the unreserved characters is escaped.
  defp encode(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  # ── shell bookkeeping ────────────────────────────────────────────────

  # The exec with the wrapper's line cut back out of stdout, and the line.
  # A command that never reached the wrapper -- killed on the timeout, say --
  # printed no marker, and then the caller's own cwd is still the best answer.
  defp split_cwd(%Shapes.Exec{stdout: stdout} = ran, cwd) do
    needle = "\n" <> @cwd_marker

    case :binary.matches(stdout, needle) do
      [] ->
        {ran, cwd}

      matches ->
        {index, _length} = List.last(matches)
        start = index + byte_size(needle)
        rest = binary_part(stdout, start, byte_size(stdout) - start)
        [line | _] = String.split(rest, "\n", parts: 2)

        {%Shapes.Exec{ran | stdout: binary_part(stdout, 0, index)},
         blank_to(String.trim(line), cwd)}
    end
  end

  defp blank_to("", default), do: default
  defp blank_to(value, _default), do: value

  # The same normalisation `Ravix.Tracks.Files.confine/2` needs, and the same
  # answer: `Path.expand/1`. Both had their own copy of a four-clause
  # reduction over the segments, which is a port of a JavaScript helper and
  # is what the standard library already does.
  defp normalize_posix(path), do: Path.expand(path, "/")

  # The last 32,000 bytes, without a torn multibyte character at the front.
  defp tail(text) when is_binary(text) and byte_size(text) <= @tail, do: text

  defp tail(text) when is_binary(text) do
    text |> binary_part(byte_size(text) - @tail, @tail) |> drop_continuation()
  end

  defp tail(_other), do: ""

  defp drop_continuation(<<byte, rest::binary>>) when byte >= 0x80 and byte < 0xC0,
    do: drop_continuation(rest)

  defp drop_continuation(text), do: text
end
