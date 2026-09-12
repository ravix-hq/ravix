defmodule Ravix.Trace.Setup do
  @moduledoc """
  Attaches the off-the-shelf instrumentation, once, at boot (ADR 0004).

  Called from `Ravix.Application.start/2` before the endpoint, because a
  handler attached after the first request is a handler that missed it.

  Three libraries:

    * `OpentelemetryBandit` produces the server span for an HTTP request.
      `OpentelemetryPhoenix` with `adapter: :bandit` deliberately does *not* --
      its endpoint handler returns `:ok` for Bandit and leaves the span to
      Bandit's own telemetry -- so both are required and neither is redundant.

    * `OpentelemetryPhoenix` names that span for the matched route, and adds
      LiveView `mount`, `handle_params` and `handle_event`. Those three are the
      whole of what LiveView emits spans for.

    * `OpentelemetryEcto` spans queries on `[:ravix, :repo, :query]`, the same
      prefix `RavixWeb.Telemetry`'s summaries read.

  `db_statement: :enabled` sends the query text. It is SQL this repository
  wrote, with parameters separated out by Postgrex rather than interpolated, so
  the values are not in the statement and no user data travels with it. Worth
  stating because it is the one line in this module where "send it to a third
  party" is a choice rather than a default.

  ## What LiveView does not span, and what this application does instead

  `handle_info`, `handle_async` and `render` produce no OpenTelemetry span, and
  on this application that is most of the work: the track page's detail, queue
  and panel reads are `start_async/3` answered in `handle_async/3`, and its
  transcript arrives as messages.

  `attach_hook/4` is not the answer. A hook runs *before* a callback and
  returns `{:cont, socket}`; it cannot wrap one, so timing a `handle_info`
  through hooks means opening a span in one stage and hoping `:after_render`
  arrives to close it -- and a message that changes no assign never renders, so
  that span would leak. A leaked span is worse than a missing one: the exporter
  holds it until the process dies.

  What closes the gap instead is spanning the *work* rather than the callback.
  `Ravix.Trace.link/1` carries the current context into the `start_async` fun,
  and the context call inside it is spanned at its own boundary, so a click
  that reads Fountain twice shows both reads under the event that asked for
  them. `handle_async/3` is then a sibling rather than a child, which is
  accurate -- it really is separate work arriving on a message.

  `render` is left alone deliberately. LiveView renders in `handle_changed`,
  *after* the `handle_event` span has closed, so a render span can never have a
  parent: every one would be a root trace, and a transcript flush would file
  thousands of one-span traces for a cost that is only interesting as a
  distribution. Per-event render cost is the subject of #126--#130 and is worth
  measuring -- as a metric, through `RavixWeb.Telemetry`, which needs a
  reporter this decision does not add.
  """

  @doc "Attach every trace handler. Called once, from `Ravix.Application.start/2`."
  @spec setup() :: :ok
  def setup do
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit, liveview: true)
    OpentelemetryEcto.setup([:ravix, :repo], db_statement: :enabled)
    :ok
  end
end
