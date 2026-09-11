defmodule Ravix.ClockTest do
  use ExUnit.Case, async: true

  alias Ravix.Clock

  setup do
    on_exit(fn -> Clock.freeze(nil) end)
    :ok
  end

  test "unfrozen, it reads the system clock" do
    before = System.system_time(:millisecond)
    now = Clock.now_ms()
    later = System.system_time(:millisecond)

    assert now >= before and now <= later
  end

  test "freezing pins the answer for this process, and thawing releases it" do
    Clock.freeze(1_700_000_000_000)
    assert Clock.now_ms() == 1_700_000_000_000
    assert Clock.now_ms() == 1_700_000_000_000

    Clock.freeze(nil)
    assert Clock.now_ms() != 1_700_000_000_000
  end

  test "a frozen clock is this process's own, not the whole node's" do
    Clock.freeze(1_700_000_000_000)
    test = self()

    spawn(fn -> send(test, {:elsewhere, Clock.now_ms()}) end)

    assert_receive {:elsewhere, elsewhere}, 1_000
    assert elsewhere != 1_700_000_000_000
    assert Clock.now_ms() == 1_700_000_000_000
  end

  test "freezing to zero is a frozen clock, not an absent one" do
    # `Process.get/1` answering the pinned value rather than a falsy one:
    # zero is a legitimate instant to pin, and `|| System.system_time/1`
    # would answer the real clock for it.
    Clock.freeze(0)
    assert Clock.now_ms() == 0
  end

  test "sleeping waits" do
    before = System.monotonic_time(:millisecond)
    assert :ok = Clock.sleep(15)
    assert System.monotonic_time(:millisecond) - before >= 10
  end
end
