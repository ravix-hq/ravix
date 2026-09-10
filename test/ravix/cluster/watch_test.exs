defmodule Ravix.Cluster.WatchTest do
  @moduledoc """
  The log lines are the interface here — they are the only way to see cluster
  membership on a deployment with shell access turned off — so they are what
  these assert on, wording included.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Ravix.Cluster.Watch

  # `config/test.exs` runs the logger at :warning and these lines are :info on
  # purpose -- membership is news, not a problem, and production runs at :info
  # where they will be read. The primary level filters before any capture sees
  # the message, so it is the level itself that has to move, not the capture's.
  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

  # The application already starts one; these drive their own so the settle
  # window does not have to be waited out.
  defp start_watch(settle_ms) do
    start_supervised!(%{
      id: {Watch, make_ref()},
      start: {GenServer, :start_link, [Watch, [settle_ms: settle_ms], []]}
    })
  end

  test "says it is alone when it is, without crying wolf about it" do
    log = capture_log(fn -> start_watch(0) && Process.sleep(60) end)

    assert log =~ "cluster of one"
    assert log =~ to_string(node())
    # One instance is a legitimate deployment and every developer machine is
    # one; a warning here is how a real one gets ignored.
    refute log =~ "[warning]"
    refute log =~ "[error]"
  end

  test "reports a node joining and leaving, and what is left after" do
    watch = start_watch(60_000)

    joined =
      capture_log(fn -> send(watch, {:nodeup, :"peer@127.0.0.1"}) && Process.sleep(60) end)

    assert joined =~ "peer@127.0.0.1 joined"

    left =
      capture_log(fn -> send(watch, {:nodedown, :"peer@127.0.0.1"}) && Process.sleep(60) end)

    assert left =~ "peer@127.0.0.1 left"
    # What remains, not only what went: during a deploy the interesting number
    # is how many are still there.
    assert left =~ "now "
  end

  test "ignores messages that are not about membership" do
    watch = start_watch(60_000)

    log = capture_log(fn -> send(watch, :something_else) && Process.sleep(40) end)

    # This module's own lines, not everybody's. `capture_log/1` sees the whole
    # VM's log, and a crash report belonging to an async test that has already
    # finished can still be written inside this window -- `Ravix.Cluster.
    # Singleton` logs "ravix: singleton ... could not start" at :error, which
    # the test log level does not suppress. Asserting on any "ravix: " line
    # made this test fail on somebody else's noise, roughly one run in ten.
    refute log =~ ~r/ravix: (.+ (joined|left); now |cluster of one|clustered;)/
    assert Process.alive?(watch)
  end

  test "peers/0 answers the same question the log does" do
    assert Watch.peers() == Node.list()
  end
end
