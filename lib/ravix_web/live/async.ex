defmodule RavixWeb.Live.Async do
  @moduledoc """
  `start_async/3`, with the trace carried into the task (ADR 0004).

  Both pages do nearly all of their reading off the LiveView process, because a
  page that reads inline stops drawing, stops answering clicks and stops taking
  transcript events for as long as Fountain takes to answer --- the comment
  above `refresh_detail/1` in `RavixWeb.TrackLive` is about exactly that. There
  are around twenty such reads across the two pages.

  OpenTelemetry's current span lives in the process dictionary, so none of them
  inherits it. Traced as they stand, a click that reads Fountain twice produces
  three unrelated traces --- the `handle_event`, and two orphans --- and the
  waterfall that would have shown *which* of the two reads was slow does not
  exist. `Ravix.Trace.link/1` is the fix, and this wrapper is here so that
  remembering it is not a per-call-site act of discipline.

  Imported into every LiveView and LiveComponent by `RavixWeb.live_view/0`.

  Use it for a read whose duration is worth knowing. `start_async/3` itself
  stays available and stays correct for work that is not: the point is a
  waterfall somebody will read, not a span on every task.
  """

  alias Phoenix.LiveView.Socket
  alias Ravix.Trace

  # `start_async/3` is a macro, so it is required rather than aliased.
  require Phoenix.LiveView

  @doc """
  `Phoenix.LiveView.start_async/3`, with the current trace context attached
  inside the task.

      socket
      |> update_panel(&Panel.loading/1)
      |> traced_async(:panel, fn -> Tracks.files(user, id, path) end)

  Everything else about it is `start_async/3`'s: the name still supersedes an
  earlier task of the same name, and the answer still arrives at
  `handle_async/3`. The span the work runs under belongs to whatever asked ---
  a `handle_event`, or nothing at all when the caller is `handle_info/2`, which
  LiveView does not span.
  """
  @spec traced_async(Socket.t(), term(), (-> term())) :: Socket.t()
  def traced_async(%Socket{} = socket, name, fun) when is_function(fun, 0) do
    Phoenix.LiveView.start_async(socket, name, Trace.link(fun))
  end
end
