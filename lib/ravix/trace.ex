defmodule Ravix.Trace do
  @moduledoc """
  Ravix's one door onto OpenTelemetry (ADR 0004).

  Contexts and LiveViews call `span/3`; nothing else in `lib/` names
  `OpenTelemetry` or `:otel_*`. That is not tidiness. Three things about this
  application make a single door the difference between tracing that helps and
  tracing that hurts, and each of them is enforced here rather than remembered
  at two hundred call sites.

  ## A span attribute is a place credentials leak

  `Ravix.Config` makes a leaked secret hard by giving every credential-bearing
  value a redacting `Inspect`, so a log line, a crash report or a `dbg/1`
  prints `...` instead of the key every machine on this deployment runs on.
  **A span attribute is not an `Inspect`.** `OpenTelemetry.Tracer.set_attribute`
  reaches into the term itself, so the one mechanism protecting the rest of the
  application does not protect this one, and a well-meaning
  `span("fountain.get", %{client: client}, ...)` would ship the key to a
  third party on every call.

  So `sanitize/1` runs over every attribute map before it reaches a span, and
  it is deliberately a whitelist of shapes rather than a blacklist of names:
  anything that is not a number, a boolean, an atom or a short binary is
  dropped, which means a struct, a map, a pid, a function and a charlist can
  never be an attribute however it was named. On top of that, a key that
  *reads* like a credential is dropped even when its value is a plain string,
  because `%{token: "ghs_..."}` is a binary and would otherwise pass. Both
  rules are tested; see `test/ravix/trace_test.exs`.

  ## A span that outlives its request is worse than no span

  `Ravix.Tracks.Follower` holds one Fountain event stream open for as long as
  anybody anywhere is looking at a transcript -- hours. `Ravix.Sprites.Tunnel`
  holds a websocket. A span around either is a span that never ends, and an
  unended span is not a slow operation on a waterfall: it is a trace the
  exporter holds until the process dies, and a bill for it. **Nothing here spans
  a stream**, and the two places that could are checked rather than assumed:
  `Ravix.Fountain.stream_events/3` hands back a lazy stream without going
  through the `call/4` funnel the span is on, and the tunnel is spanned nowhere.
  A stream's lifetime stays what it was, a log line.

  This is also why outbound HTTP is spanned at Ravix's boundaries --
  `Ravix.Fountain`, `Ravix.Sprites`, `Ravix.GitHub` -- rather than by hanging
  an instrumentation plug on the HTTP client. A client-level plug cannot tell
  `Tracks.get/2`'s two round trips from a stream that will still be open at
  midnight, and it would name the span for a URL when the useful name is the
  question being asked.

  ## The work happens in another process

  OpenTelemetry's current span lives in the process dictionary, so it does not
  cross a process boundary. This application does almost nothing in the process
  that decided to do it: a LiveView's reads are `start_async/3`, the preview
  server's operations are `Task.Supervisor.async_nolink/2`, and a context's
  background work belongs under `Ravix.TaskSupervisor`. Instrumented naively,
  every one of those produces an orphan trace with one span in it and no clue
  which click caused it.

  `link/1` is the fix and it is one word at the call site: it captures the
  current context where the work is *decided* and attaches it where the work
  *runs*, so

      start_async(socket, :detail, Trace.link(fn -> Tracks.get(user, id) end))

  puts the read under the event that asked for it -- and
  `RavixWeb.Live.Async.traced_async/3` exists so that no page has to remember
  it. `handle_async/3` is back in the LiveView process and is not spanned at
  all, because LiveView emits nothing for it; what it does is assign and
  render, and the read it is answering is already on the waterfall.

  `carrier/0` is the same mechanism for the one case that has no closure to
  wrap: `Ravix.Previews.Server` queues its operations as data, so the context
  travels beside the operation in the message instead.

  ## What is not here

  No metrics and no logs. `RavixWeb.Telemetry` still owns `Telemetry.Metrics`
  and the VM poller, and Honeycomb gets traces only. Adding an OTLP log handler
  would put every `Logger` line through a third party, which is a separate
  decision about a much larger surface than this one.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @typedoc """
  Attributes for a span. Values survive `sanitize/1` only if they are numbers,
  booleans, atoms or binaries; keys that read like a credential never do.
  """
  @type attributes :: %{optional(atom() | String.t()) => term()}

  # Long enough for an id, a branch name, a provider's error string or a
  # sanitised message; short enough that no single attribute can carry a file,
  # a diff or a transcript into a trace by accident. A truncated value keeps a
  # marker so a reader knows the value is not the whole of it.
  @max_binary 256

  # Dropped whatever the value looks like. `key` catches `api_key`,
  # `private_key` and `secret_key`; `auth` catches `authorization` and
  # `auth_token`. Over-broad on purpose: a dropped attribute costs a reader one
  # field, and a kept one costs a credential.
  #
  # One case-insensitive regex rather than ten `String.contains?/2` over a
  # downcased copy of the key: this runs per attribute on every span that
  # records, and the list form was two thirds of the cost of `span/3`.
  @secretish ~w(token secret key password passwd credential auth pem signature cookie)
  @secretish_pattern ~r/#{Enum.join(@secretish, "|")}/i

  @doc """
  Run `fun` as a span named `name`, with `attributes`.

  The span records an error and re-raises on an exception, and is marked
  `:error` when `fun` answers a tagged error -- a `{:error, reason}` from a
  context is the failure this trace exists to show, and a trace where every
  span is green because the failures were returned rather than raised is
  worse than none.

      Trace.span("tracks.get", %{"ravix.track_id" => id}, fn ->
        Tracks.get(user, id)
      end)

  The `{:error, _}` convention is Ravix's own (contexts return tagged results),
  so it is read here rather than left to each caller to remember.
  """
  @spec span(String.t(), attributes(), (-> result)) :: result when result: term()
  def span(name, attributes \\ %{}, fun) when is_binary(name) and is_function(fun, 0) do
    Tracer.with_span name, %{} do
      # Sanitised and attached *after* the span starts, and only if it is
      # recording. `sanitize/1` is by far the expensive half of this module, and
      # on a deployment with no exporter configured -- `sampler: :always_off` in
      # `config/config.exs` -- every span is non-recording, so doing this work
      # before the sampler has spoken would be the whole cost of tracing paid by
      # somebody who switched tracing off. Measured: 8.2us a span before this,
      # 1.1us after.
      #
      # The trade is that attributes are no longer visible to the sampler at
      # span start. Nothing here samples on attributes (parent-based over a
      # ratio), and an attribute-based sampler would need this moved back.
      annotate(attributes)

      case fun.() do
        {:error, reason} = result ->
          # The reason itself, not just "it failed": `:unconfigured`,
          # `:not_found` and a provider's 502 are three different problems and
          # only one of them is worth being woken for.
          described = reason_attribute(reason)
          Tracer.set_attribute(:"ravix.error", true)
          Tracer.set_attribute(:"ravix.error_reason", described)
          Tracer.set_status(OpenTelemetry.status(:error, to_string(described)))
          result

        result ->
          result
      end
    end
  end

  @doc """
  Add attributes to the span already running, if one is.

  For what is only known once the work is done -- how many events a read
  returned, which of four failure states the terminal is in. Outside a span
  this is a no-op rather than an error, which is what lets a context be called
  from a test, a sweep or `iex` without a span having been opened for it.
  """
  @spec annotate(attributes()) :: :ok
  def annotate(attributes) do
    # The `is_recording` check is what keeps `sanitize/1` off the path of a
    # deployment that is not exporting, and off the path of a trace the sampler
    # has dropped. Outside a span entirely, `current_span_ctx/0` is `:undefined`
    # and this is the no-op a sweep, a test or `iex` needs it to be.
    if recording?(), do: Tracer.set_attributes(sanitize(attributes))
    :ok
  end

  defp recording? do
    case Tracer.current_span_ctx() do
      :undefined -> false
      ctx -> OpenTelemetry.Span.is_recording(ctx)
    end
  end

  @doc """
  Wrap `fun` so that it runs under the context current *now*.

  For `start_async/3`, `Task.Supervisor.async_nolink/2` and anything else that
  moves work to another process. See the moduledoc: without this the work is a
  trace of its own with nothing pointing at what asked for it.

      start_async(socket, :queue, Trace.link(fn -> PromptQueue.list(user, id) end))

  The captured context is detached again afterwards, so a pooled or reused
  process cannot inherit a finished request's trace and file its next job under
  it -- which is the failure mode that makes traces look *wrong* rather than
  missing, and the reason this returns a wrapper instead of exposing the
  attach.
  """
  @spec link((-> result)) :: (-> result) when result: term()
  def link(fun) when is_function(fun, 0) do
    carry = carrier()
    fn -> carry.(fun) end
  end

  @doc """
  The current context, as something that can run a function under it later.

  `link/1` is the form to reach for; this is for the case `link/1` cannot serve,
  where the work is not a closure when it crosses the boundary.
  `Ravix.Previews.Server` is that case: an operation is queued as *data*
  (`:start`, `{:service, name}`) because only the server knows the track, the
  lease and the owner to perform it with, so there is no function to wrap at the
  point the caller still has a context. A carrier travels in the message
  alongside the operation instead, and the task runs under it.

  Capture it in the process that has the context -- the caller -- and use it in
  the process that does the work. It is an ordinary closure over a context term,
  so it survives a `GenServer.call` and, on this cluster, a hop to another node.
  """
  @spec carrier() :: ((-> result) -> result) when result: term()
  def carrier do
    context = OpenTelemetry.Ctx.get_current()

    fn fun when is_function(fun, 0) ->
      token = OpenTelemetry.Ctx.attach(context)

      try do
        fun.()
      after
        # Detached even on a raise, so a supervised task process that outlives
        # this call cannot file its next, unrelated job as a child of this
        # trace. That failure makes traces look wrong rather than missing,
        # which is worse.
        OpenTelemetry.Ctx.detach(token)
      end
    end
  end

  @doc """
  Run `fun` with tracing off: no span inside it is recorded or exported.

  For recurring background work that is almost always a no-op. The prompt
  queue's sweep is the case this exists for: it runs every two seconds on
  *every* instance (ADR 0003 keeps it there deliberately, because it is
  idempotent and merely cheaper once), and almost every run finds nothing to
  do. Two Ecto queries with no parent span are two root traces, so left alone
  that sweep files something like eighty thousand traces a day per instance,
  all of them empty, and Honeycomb charges for every one.

  The mechanism is the sampler rather than a flag: this makes a non-recording,
  not-sampled span current, and the parent-based sampler configured in
  `config/config.exs` drops every child of a parent that was not sampled. So it
  suppresses instrumentation nobody here wrote --- Ecto's --- as well as
  `span/3`.

  It suppresses *this process*, for the duration. Work handed to another
  process is not suppressed, because a fresh process has a fresh context: that
  is how `Ravix.PromptQueue.Server` keeps its sweep silent while each actual
  delivery, which runs in a task, still gets a trace of its own.
  """
  @spec untraced((-> result)) :: result when result: term()
  def untraced(fun) when is_function(fun, 0) do
    # A non-recording span context, made current. Its `trace_flags` are 0, which
    # is what routes every child through the parent-based sampler's
    # `local_parent_not_sampled` branch -- `always_off`.
    suppressed =
      Tracer.set_current_span(
        OpenTelemetry.Ctx.get_current(),
        :otel_tracer_noop.noop_span_ctx()
      )

    token = OpenTelemetry.Ctx.attach(suppressed)

    try do
      fun.()
    after
      OpenTelemetry.Ctx.detach(token)
    end
  end

  @doc """
  The attributes that survive being put on a span.

  Public because it is the security-relevant half of this module and is tested
  directly; call `span/3` or `annotate/1` rather than this.

  Dropped: any value that is not a number, boolean, atom or binary (so structs,
  maps, lists, pids, refs and functions never reach a span), any binary over
  #{@max_binary} bytes, which is truncated rather than dropped, any key whose
  name reads like a credential, and any key that is not an atom or a string.

  Total, on purpose: this cannot raise on any map it is given. A telemetry call
  that crashes the request it was measuring is a worse outcome than any missing
  attribute, and `span/3` is called from every context boundary.
  """
  @spec sanitize(attributes()) :: %{optional(atom() | String.t()) => term()}
  def sanitize(attributes) when is_map(attributes) do
    attributes
    |> Enum.reject(fn {key, _value} -> secretish?(key) end)
    |> Enum.flat_map(fn {key, value} ->
      case value(value) do
        {:ok, safe} -> [{key, safe}]
        :drop -> []
      end
    end)
    |> Map.new()
  end

  # `{:ok, term} | :drop`. The last clause is the one that matters: a shape
  # this does not recognise is dropped rather than guessed at, so a value type
  # nobody thought about here cannot reach a span by default.
  defp value(v) when is_number(v) or is_boolean(v) or is_atom(v), do: {:ok, v}

  defp value(v) when is_binary(v) do
    # A binary that is not text is a payload, a compiled key or a serialised
    # term. None of those belong on a span and one of them is a credential.
    if String.valid?(v), do: {:ok, truncate(v)}, else: :drop
  end

  defp value(_other), do: :drop

  defp truncate(text) do
    if byte_size(text) > @max_binary do
      # Sliced by bytes and then repaired, because a UTF-8 sequence cut in
      # half is not a string the exporter can encode.
      <<head::binary-size(@max_binary), _rest::binary>> = text
      String.replace_invalid(head, "") <> "…"
    else
      text
    end
  end

  # `true` also means "drop", so a key this cannot read is dropped rather than
  # examined. Anything but an atom or a string is not a valid attribute key in
  # the first place, and `to_string/1` on, say, a pid raises -- which would make
  # a telemetry call take down the request it was measuring. Nothing observing
  # this application may do that.
  defp secretish?(key) when is_atom(key), do: secretish?(Atom.to_string(key))
  defp secretish?(key) when is_binary(key), do: Regex.match?(@secretish_pattern, key)
  defp secretish?(_key), do: true

  # A tagged error's reason, as something a trace can hold and a person can
  # group by. An atom stays an atom; anything else is described rather than
  # inspected, because `inspect/1` on a struct that carries a credential is the
  # leak this module exists to prevent and a reason is sometimes a struct.
  defp reason_attribute(reason) when is_atom(reason), do: reason

  defp reason_attribute(reason) when is_binary(reason), do: truncate(reason)

  defp reason_attribute({tag, _detail}) when is_atom(tag), do: tag

  defp reason_attribute(%module{}), do: inspect(module)

  defp reason_attribute(_other), do: :unknown
end
