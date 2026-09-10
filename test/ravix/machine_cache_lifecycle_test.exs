defmodule Ravix.MachineCacheLifecycleTest do
  use ExUnit.Case, async: false
  alias Ravix.{Fountain.FakeTransport, MachineCache}

  test "reset lets an existing caller finish without caching its stale answer" do
    client = FakeTransport.client([])
    parent = self()

    caller =
      Task.async(fn ->
        MachineCache.sprite_name(client, "reset-sandbox", fn ->
          send(parent, {:loading, self()})

          receive do
            :finish -> "old-sprite"
          after
            2_000 -> flunk("loader was not released")
          end
        end)
      end)

    assert_receive {:loading, loader}
    MachineCache.reset()
    send(loader, :finish)
    assert Task.await(caller, 3_000) == "old-sprite"

    assert MachineCache.sprite_name(client, "reset-sandbox", fn -> "new-sprite" end) ==
             "new-sprite"
  end

  @tag capture_log: true
  test "a crashed load answers all waiters and a later call can recover" do
    client = FakeTransport.client([])
    assert MachineCache.sprite_name(client, "crash", fn -> exit(:provider_died) end) == nil
    assert MachineCache.sprite_name(client, "crash", fn -> "recovered" end) == "recovered"
  end

  test "raised loader errors are not cached" do
    client = FakeTransport.client([])
    assert MachineCache.sprite_name(client, "raises", fn -> raise "bad provider" end) == nil
    assert MachineCache.sprite_name(client, "raises", fn -> "recovered" end) == "recovered"
  end
end
