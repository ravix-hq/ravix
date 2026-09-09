defmodule Ravix.GitHub.Clock do
  @moduledoc """
  The one clock the GitHub client reads.

  Token expiry, rate-limit windows and the checks cache are all "is it later
  than X yet" questions, and the tests for them need to move time rather than
  wait for it. Every read goes through `now_ms/0`, which a test can pin for
  its own process with `freeze/1`. Nothing outside the test suite calls
  `freeze/1`; production always reads the system clock.
  """

  @key :ravix_github_now_ms

  @doc "Milliseconds since the epoch, or the value this process froze."
  @spec now_ms() :: integer()
  def now_ms, do: Process.get(@key) || System.system_time(:millisecond)

  @doc "Pin `now_ms/0` for the calling process (tests). `nil` thaws it."
  @spec freeze(integer() | nil) :: :ok
  def freeze(nil) do
    Process.delete(@key)
    :ok
  end

  def freeze(ms) when is_integer(ms) do
    Process.put(@key, ms)
    :ok
  end
end
