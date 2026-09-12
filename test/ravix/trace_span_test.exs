defmodule Ravix.TraceSpanTest do
  @moduledoc """
  What `Ravix.Trace` actually puts on the wire, read back through the in-memory
  exporter. `Ravix.TraceTest` covers `sanitize/1` without needing one.

  `async: false` because the exporter is a global setting on the tracer
  provider; `Ravix.TraceCase` says why.
  """
  use Ravix.TraceCase, async: false

  alias Ravix.Trace

  describe "span/3" do
    test "names the span and keeps its attributes" do
      assert Trace.span("tracks.get", %{"ravix.track_id" => "trk_1"}, fn -> {:ok, :detail} end) ==
               {:ok, :detail}

      assert_receive {:span, recorded = span(name: "tracks.get")}
      assert attributes(recorded)["ravix.track_id"] == "trk_1"
    end

    test "a credential handed in as an attribute never reaches the exporter" do
      # The end-to-end form of `Ravix.TraceTest`'s unit assertions: the drop
      # happens inside `span/3`, not only in a function a caller might bypass.
      sprites = %Ravix.Config.Sprites{token: "spr_live_secret", base_url: "https://x"}

      Trace.span(
        "sprites.exec",
        %{"ravix.sprites" => sprites, "token" => "spr_live_secret"},
        fn ->
          :ok
        end
      )

      assert_receive {:span, recorded = span(name: "sprites.exec")}
      assert attributes(recorded) == %{}
      refute inspect(recorded) =~ "spr_live_secret"
    end

    test "a tagged error marks the span, with the reason" do
      # Contexts return tagged results, so a trace that only reddens on a raise
      # would show every one of this application's real failures as a success.
      assert Trace.span("fountain.get", %{}, fn -> {:error, :unconfigured} end) ==
               {:error, :unconfigured}

      assert_receive {:span, recorded = span(name: "fountain.get", status: recorded_status)}
      assert attributes(recorded)[:"ravix.error"] == true
      assert attributes(recorded)[:"ravix.error_reason"] == :unconfigured
      assert status(recorded_status, :code) == :error
    end

    test "a tagged error whose reason is a struct is described, not inspected" do
      # A reason is sometimes a struct, and `inspect/1` on one that carries a
      # credential is exactly the leak this module exists to prevent.
      reason = %Ravix.Config.Sprites{token: "spr_live_secret", base_url: "https://x"}

      Trace.span("sprites.exec", %{}, fn -> {:error, reason} end)

      assert_receive {:span, recorded = span(name: "sprites.exec")}
      assert attributes(recorded)[:"ravix.error_reason"] == "Ravix.Config.Sprites"
      refute inspect(recorded) =~ "spr_live_secret"
    end

    test "a two-element error reason is recorded by its tag" do
      Trace.span("github.checks", %{}, fn -> {:error, {:http, 502}} end)

      assert_receive {:span, recorded = span(name: "github.checks")}
      assert attributes(recorded)[:"ravix.error_reason"] == :http
    end

    test "a string error reason is kept, truncated" do
      long = String.duplicate("Fountain said 502. ", 40)
      Trace.span("fountain.request", %{}, fn -> {:error, long} end)

      assert_receive {:span, recorded = span(name: "fountain.request")}
      reason = attributes(recorded)[:"ravix.error_reason"]
      assert String.starts_with?(reason, "Fountain said 502.")
      assert byte_size(reason) < byte_size(long)
    end

    test "an error reason of a shape nobody planned for is :unknown, not a leak" do
      # The last clause matters more than it looks: an unrecognised reason
      # described by `inspect/1` is how a credential ends up on a span.
      Trace.span("previews.operation", %{}, fn -> {:error, [%{token: "spr_secret"}]} end)

      assert_receive {:span, recorded = span(name: "previews.operation")}
      assert attributes(recorded)[:"ravix.error_reason"] == :unknown
      refute inspect(recorded) =~ "spr_secret"
    end

    test "an :ok tuple leaves the span unmarked" do
      Trace.span("tracks.events", %{}, fn -> {:ok, []} end)

      assert_receive {:span, recorded = span(name: "tracks.events")}
      refute Map.has_key?(attributes(recorded), :"ravix.error")
    end

    test "a raise is recorded and re-raised" do
      assert_raise RuntimeError, "boom", fn ->
        Trace.span("previews.start", %{}, fn -> raise "boom" end)
      end

      assert_receive {:span, span(name: "previews.start")}
    end
  end

  describe "annotate/1" do
    test "adds to the span already running" do
      Trace.span("tracks.events", %{}, fn ->
        Trace.annotate(%{"ravix.event_count" => 41})
        :ok
      end)

      assert_receive {:span, recorded = span(name: "tracks.events")}
      assert attributes(recorded)["ravix.event_count"] == 41
    end

    test "outside a span it is a no-op rather than an error" do
      # Every context function that annotates is also called from a sweep, a
      # test and `iex`, where nobody opened a span for it.
      assert Trace.annotate(%{"ravix.event_count" => 1}) == :ok
    end

    test "it sanitizes too" do
      Trace.span("tracks.events", %{}, fn ->
        Trace.annotate(%{"token" => "ghs_x"})
        :ok
      end)

      assert_receive {:span, recorded = span(name: "tracks.events")}
      assert attributes(recorded) == %{}
    end
  end

  describe "untraced/1" do
    test "a span inside it is never exported" do
      Trace.untraced(fn -> Trace.span("prompt_queue.sweep", %{}, fn -> :ok end) end)

      refute_receive {:span, _}
    end

    test "it returns the value, and tracing resumes after it" do
      assert Trace.untraced(fn -> :swept end) == :swept

      Trace.span("after", %{}, fn -> :ok end)
      assert_receive {:span, span(name: "after")}
    end

    test "suppression does not escape a raise" do
      assert_raise RuntimeError, "boom", fn -> Trace.untraced(fn -> raise "boom" end) end

      Trace.span("after", %{}, fn -> :ok end)
      assert_receive {:span, span(name: "after")}
    end

    test "work handed to another process is not suppressed" do
      # This is what keeps the prompt queue's sweep silent while each actual
      # delivery, which runs in its own task, still gets a trace.
      parent = self()

      Trace.untraced(fn ->
        {:ok, _} =
          Task.start(fn ->
            Trace.span("prompt_queue.deliver", %{}, fn -> :ok end)
            send(parent, :delivered)
          end)

        assert_receive :delivered
      end)

      assert_receive {:span, span(name: "prompt_queue.deliver")}
    end
  end

  describe "link/1 across a process boundary" do
    test "work in another process becomes a child of the span that asked for it" do
      # The failure this prevents: OpenTelemetry's current span lives in the
      # process dictionary, so every `start_async/3` read in this application
      # would otherwise be an orphan trace with one span in it and nothing
      # naming the click that caused it.
      parent = self()

      Trace.span("live.handle_event", %{}, fn ->
        work = Trace.link(fn -> Trace.span("tracks.get", %{}, fn -> :ok end) end)
        {:ok, task} = Task.start(fn -> send(parent, {:done, work.()}) end)
        assert_receive {:done, :ok}
        task
      end)

      assert_receive {:span,
                      span(name: "tracks.get", trace_id: child_trace, parent_span_id: linked)}

      assert_receive {:span,
                      span(
                        name: "live.handle_event",
                        trace_id: parent_trace,
                        span_id: parent_span
                      )}

      assert child_trace == parent_trace
      assert linked == parent_span
    end

    test "without link/1 the same work is an orphan" do
      # Stated as a test so that someone removing a `Trace.link` from a
      # `start_async` call sees what it costs rather than guessing.
      parent = self()

      Trace.span("live.handle_event", %{}, fn ->
        {:ok, _} =
          Task.start(fn ->
            send(parent, {:done, Trace.span("tracks.get", %{}, fn -> :ok end)})
          end)

        assert_receive {:done, :ok}
      end)

      assert_receive {:span, span(name: "tracks.get", parent_span_id: orphaned)}
      assert orphaned == :undefined
    end
  end
end
