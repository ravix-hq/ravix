defmodule Ravix.TraceCase do
  @moduledoc """
  Reads finished spans back, so a test can assert on what tracing actually
  produced rather than on the fact that a function was called.

  `config/test.exs` runs the `:simple` span processor with no exporter, so
  spans are built and dropped. This swaps in `:otel_exporter_pid`, which sends
  each finished span to the test process as `{:span, record}` -- so an
  assertion is a message match, not a sleep waiting for a batch timer. That is
  the whole reason the processor is `:simple` rather than `:batch` under test.

      use Ravix.TraceCase, async: false

      test "the read is a span" do
        Ravix.Trace.span("tracks.get", %{}, fn -> :ok end)
        assert_receive {:span, span(name: "tracks.get")}
      end

  `async: false`, always: the exporter is one global setting on the tracer
  provider, so two tests swapping it at once would each receive the other's
  spans. Anything that only needs `Ravix.Trace.sanitize/1` should use a plain
  `ExUnit.Case` and stay async instead.
  """

  use ExUnit.CaseTemplate

  require Record

  using do
    quote do
      import Ravix.TraceCase

      require Record

      # The span record as the SDK defines it, so a test can match on
      # `name:`, `attributes:`, `parent_span_id:` and `status:` by name
      # instead of by tuple position.
      Record.defrecordp(
        :span,
        Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
      )

      Record.defrecordp(
        :status,
        Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
      )
    end
  end

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

    on_exit(fn ->
      # Point the exporter at a process that is already gone, so spans from the
      # rest of the suite are discarded rather than arriving as `{:span, _}` in
      # some later test's mailbox. `send/2` to a dead pid is a silent no-op,
      # which is exactly the sink wanted here -- `set_exporter(:none, [])` is
      # not, because every arity wraps its argument into `{module, options}` and
      # the processor then warns once per span that `:none` is not a module.
      :otel_simple_processor.set_exporter(:otel_exporter_pid, spawn(fn -> :ok end))
    end)

    :ok
  end

  @doc """
  Wait for a finished span whose name matches, discarding the ones before it.

  A page's click produces Ecto spans as well as the ones a test is about
  (`ravix.repo.query:tracks`, and one per query), so "the next span" is not a
  useful thing to assert on.

  **Non-matching spans are discarded, so ask in the order the spans end.** That
  order is not nesting order here. A `traced_async/3` child keeps running after
  the callback that started it returns, so the *parent* ends first:

      event = await_span("RavixWeb.TrackLive.handle_event#panel")
      read = await_span("tracks.files")

  Asking for the read first would throw the event span away, and the failure
  reads as "the event was never spanned" --- which is not what happened.
  """
  @spec await_span(String.t() | Regex.t(), timeout()) :: tuple()
  def await_span(name, timeout \\ 2_000) do
    await_span(name, timeout, System.monotonic_time(:millisecond) + timeout, [])
  end

  defp await_span(name, timeout, deadline, seen) do
    receive do
      {:span, recorded} ->
        if matches?(span_name(recorded), name),
          do: recorded,
          else: await_span(name, timeout, deadline, [span_name(recorded) | seen])
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        ExUnit.Assertions.flunk("""
        No span named #{inspect(name)} within #{timeout}ms.

        Spans that did finish, oldest first: #{inspect(Enum.reverse(seen))}
        """)
    end
  end

  defp matches?(actual, %Regex{} = name), do: Regex.match?(name, actual)
  defp matches?(actual, name) when is_binary(name), do: actual == name

  @doc "The name of a finished span."
  @spec span_name(tuple()) :: String.t()
  def span_name(recorded), do: recorded |> field(:name) |> to_string()

  @doc """
  One field of a finished span, by the name the SDK's record gives it.

  Resolved from the header rather than hard-coded: the record has nineteen
  fields and a release that inserts one would otherwise move a positional read
  to whatever field took its place.
  """
  @spec field(tuple(), atom()) :: term()
  def field(recorded, name) do
    fields = Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
    elem(recorded, Enum.find_index(Keyword.keys(fields), &(&1 == name)) + 1)
  end

  @doc """
  The attributes of a finished span, as a plain map.

  The SDK stores them in an `:otel_attributes` record carrying its own limits,
  which is not a thing to pattern-match in a test.
  """
  @spec attributes(tuple()) :: map()
  def attributes(recorded), do: recorded |> field(:attributes) |> :otel_attributes.map()
end
