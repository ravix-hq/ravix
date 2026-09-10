defmodule Ravix.Previews.Clock do
  @moduledoc """
  The one clock the previews read.

  Leases, idle stops, ticket expiry and the startup deadline are all "is it
  later than X yet" questions, and the reconciler test needs to walk a
  preview through them without waiting five real minutes. Every read goes
  through `now_ms/0` and every wait through `sleep/1`, so a test can stub
  both (Mimic) and move time by hand. Production reads the system clock.
  """

  @doc "Milliseconds since the epoch, what the TypeScript compared with `Date.now()`."
  @spec now_ms() :: integer()
  def now_ms, do: System.system_time(:millisecond)

  @doc "Wait; the readiness loop's half-second between probes."
  @spec sleep(non_neg_integer()) :: :ok
  def sleep(ms), do: Process.sleep(ms)
end
