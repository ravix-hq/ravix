defmodule Ravix.Clock do
  @moduledoc """
  The one clock this server reads.

  Leases, idle stops, ticket expiry, startup deadlines, installation token
  expiry, rate-limit windows and the checks cache are all "is it later than X
  yet" questions. Every one of them needs a test that can move time rather
  than wait for it, and two modules had been written to give them that --
  `Ravix.Previews.Clock` and `Ravix.GitHub.Clock` -- with the same `now_ms/0`
  over `System.system_time(:millisecond)` and *different* ways to fake it. A
  reader had to know which subsystem they were in to know how time was moved.

  Both ways are here, because both are real and neither subsumes the other.

  ## Freezing, for a test that owns the process

  `freeze/1` pins `now_ms/0` for the calling process through the process
  dictionary. Nothing outside the test suite calls it. It is the cheaper seam
  -- no stub, no global -- and it is what the GitHub tests use, because the
  token refresh and the rate-limit window are decided in the process that
  asked.

  It does not reach a process the test did not start, which is why it is not
  the only seam.

  ## Stubbing, for time that has to move somewhere else

  The previews decide across processes: the reconciler ticks, a per-track
  server runs an operation, a readiness loop sleeps between probes. A test
  walking a preview through a five-minute lease has to move time in all of
  them. So this module is `Mimic.copy/1`-ed and the preview fixture stubs
  `now_ms/0` and `sleep/1` against a clock it holds in an agent -- the stubs
  follow the test through `$callers`, and `sleep/1` *advances* that clock
  instead of waiting, which is how the reconciler test walks a preview
  through its whole lifetime without taking five real minutes.

  ## Milliseconds

  `now_ms/0` answers milliseconds since the epoch. That is what the values it
  is compared against are: `Ravix.Previews.Row`'s `last_activity`,
  `lease_until` and `started_at`, and the `expires` columns on the preview
  grants. Those are integers on disk, and this is the clock they are read
  with; a `DateTime` here would be converted at every comparison.
  """

  @key :ravix_now_ms

  @doc "Milliseconds since the epoch, or the value this process froze."
  @spec now_ms() :: integer()
  def now_ms, do: Process.get(@key) || System.system_time(:millisecond)

  @doc """
  Pin `now_ms/0` for the calling process (tests). `nil` thaws it.

  Only this process. Work handed to another one reads the real clock, or
  whatever that process was stubbed with.
  """
  @spec freeze(integer() | nil) :: :ok
  def freeze(nil) do
    Process.delete(@key)
    :ok
  end

  def freeze(ms) when is_integer(ms) do
    Process.put(@key, ms)
    :ok
  end

  @doc """
  Wait; the preview readiness loop's half-second between probes.

  Here rather than at the call site so a test stubbing this module can make
  the wait move the clock instead of the scheduler.
  """
  @spec sleep(non_neg_integer()) :: :ok
  def sleep(ms), do: Process.sleep(ms)
end
