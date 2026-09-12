defmodule Ravix.TraceInertTest do
  @moduledoc """
  A deployment that configures no exporter pays nothing (ADR 0004).

  This is the property that makes tracing safe to ship before a Honeycomb
  account exists, and the obvious reading of it is wrong. `traces_exporter:
  :none` stops spans *leaving*; it does not stop them being *made*.
  `otel_batch_processor:on_end/2` buffers every sampled span whatever the
  exporter is, and the SDK's default root sampler is `always_on` — so the
  exporter setting alone would leave an unconfigured deployment building a span,
  running `sanitize/1` and writing to an ETS table on every request, LiveView
  event and query, then dropping the lot on a five-second timer.

  `config/config.exs` therefore also sets `sampler: :always_off`, and `span/3`
  attaches attributes only when its span records. What would break without this
  file is silent and expensive: somebody drops `:always_off` as redundant beside
  `:none`, or moves `sanitize/1` back in front of the sampler, and every
  deployment with tracing switched off starts paying for it on every request.

  The configuration is read from the file rather than from this suite's own
  environment, because `config/test.exs` deliberately puts the sampler back so
  that `Ravix.TraceCase` has spans to read.
  """
  use ExUnit.Case, async: true

  alias Ravix.Trace

  require OpenTelemetry.Tracer, as: Tracer

  describe "the configuration an unconfigured deployment gets" do
    setup do
      # The real file, evaluated for a non-test environment: what a deployment
      # with no Honeycomb key actually runs on. `config/runtime.exs` is not read
      # here -- it is what *replaces* these two when a key is present.
      %{otel: Config.Reader.read!("config/config.exs", env: :prod)[:opentelemetry]}
    end

    test "declares no exporter", %{otel: otel} do
      assert otel[:traces_exporter] == :none
    end

    test "declares a sampler that records nothing", %{otel: otel} do
      assert otel[:sampler] == :always_off,
             """
             `traces_exporter: :none` alone does not make tracing free -- the SDK still
             builds and buffers every sampled span, and its default root sampler is
             `always_on`. See this module's documentation and ADR 0004.
             """
    end
  end

  describe "when a span will not record" do
    # `untraced/1` makes a non-recording span current, which is exactly the state
    # every span is in on a deployment with `sampler: :always_off` -- so it
    # reproduces that state here without touching the global tracer provider,
    # which would take every other trace test in the run with it.

    test "no attribute is examined, let alone sanitised" do
      # The tripwire is the `nil` key: `sanitize/1` is total, but
      # `OpenTelemetry.Span.set_attributes/2` is not obliged to be, and a
      # recording span would reach it. Mostly this asserts the cheaper thing --
      # that handing `span/3` junk on the inert path cannot fail.
      attributes = %{"ravix.track_id" => "t", self() => 1, nil => make_ref()}

      Trace.untraced(fn ->
        assert Trace.span("tracks.get", attributes, fn -> :ok end) == :ok
        assert Trace.annotate(attributes) == :ok
      end)
    end

    test "the span really is non-recording" do
      recording? =
        Trace.untraced(fn ->
          Trace.span("tracks.get", %{}, fn ->
            OpenTelemetry.Span.is_recording(Tracer.current_span_ctx())
          end)
        end)

      refute recording?
    end
  end

  describe "inert must mean 'costs nothing', never 'behaves differently'" do
    # Every context boundary in the application is wrapped in one of these, so a
    # difference here is a difference in the application.

    test "values pass through unchanged" do
      Trace.untraced(fn ->
        assert Trace.span("tracks.get", %{}, fn -> {:ok, :detail} end) == {:ok, :detail}

        assert Trace.span("tracks.get", %{}, fn -> {:error, :unconfigured} end) ==
                 {:error, :unconfigured}

        assert Trace.span("tracks.mark_read", %{}, fn -> :ok end) == :ok
      end)
    end

    test "a raise still propagates" do
      Trace.untraced(fn ->
        assert_raise RuntimeError, "boom", fn ->
          Trace.span("previews.start", %{}, fn -> raise "boom" end)
        end
      end)
    end

    test "annotate/1 outside any span is a no-op rather than an error" do
      assert Trace.annotate(%{"ravix.event_count" => 1}) == :ok
    end
  end
end
