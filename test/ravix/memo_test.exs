defmodule Ravix.MemoTest do
  @moduledoc """
  The four things a single-flight memo has to get right, asked of the memo
  itself rather than through one of its callers. Both `Ravix.MachineCache`
  and `Ravix.GitHub.Cache` had their own answers to these; there is one now,
  so this is where it is held to them.
  """
  use ExUnit.Case, async: true

  alias Ravix.Memo

  setup ctx do
    name = :"memo_#{:erlang.phash2(ctx.test)}"
    start_supervised!({Memo, name: name})
    %{memo: name}
  end

  defp keep(ms), do: fn _result, started -> started + ms end
  defp never, do: fn _result, _started -> nil end

  describe "hits and misses" do
    test "a value is loaded once and then read without the server", %{memo: memo} do
      me = self()
      load = fn -> send(me, :loaded) && :value end

      assert Memo.fetch(memo, :k, load, keep(60_000)) == :value
      assert_received :loaded

      assert Memo.fetch(memo, :k, load, keep(60_000)) == :value
      refute_received :loaded
    end

    test "a value stops being good on its own schedule", %{memo: memo} do
      assert Memo.fetch(memo, :k, fn -> 1 end, keep(50), now_ms: 1_000) == 1
      assert Memo.fetch(memo, :k, fn -> 2 end, keep(50), now_ms: 1_040) == 1
      assert Memo.fetch(memo, :k, fn -> 2 end, keep(50), now_ms: 1_060) == 2
    end

    test "a result the caller will not have remembered is loaded again", %{memo: memo} do
      assert Memo.fetch(memo, :k, fn -> :bad end, never()) == :bad
      assert Memo.fetch(memo, :k, fn -> :good end, keep(60_000)) == :good
    end

    test "the TTL runs from when the load started, not when it finished", %{memo: memo} do
      slow = fn -> Process.sleep(30) && :value end
      assert Memo.fetch(memo, :k, slow, keep(20), now_ms: 1_000) == :value
      # Started at 1_000 and good for 20ms, so it is stale at 1_030 even
      # though it only landed then. A slower provider must not buy a value
      # a longer life than the caller asked for.
      assert Memo.peek(memo, :k, 1_030) == :miss
    end
  end

  describe "one load for concurrent misses" do
    test "twenty callers arriving at once cause one load", %{memo: memo} do
      me = self()

      load = fn ->
        send(me, :loaded)
        Process.sleep(40)
        :value
      end

      tasks = for _ <- 1..20, do: Task.async(fn -> Memo.fetch(memo, :k, load, keep(60_000)) end)
      assert Enum.map(tasks, &Task.await/1) == List.duplicate(:value, 20)

      assert_received :loaded
      refute_received :loaded
    end
  end

  describe "invalidation while a load is in flight" do
    test "the waiters are answered and the answer is not remembered", %{memo: memo} do
      me = self()

      load = fn ->
        send(me, {:started, self()})

        receive do
          :go -> :stale
        after
          1_000 -> flunk("the load was never released")
        end
      end

      waiter = Task.async(fn -> Memo.fetch(memo, :k, load, keep(60_000)) end)
      assert_receive {:started, loader}, 1_000

      # Forgotten after the load began: it was started before whatever
      # invalidated the key, so its answer is already out of date.
      :ok = Memo.forget(memo, :k)
      send(loader, :go)

      assert Task.await(waiter) == :stale
      assert Memo.peek(memo, :k) == :miss
    end

    test "forget_where takes a family of keys and leaves the rest", %{memo: memo} do
      for k <- [{:p, 1}, {:p, 2}, {:q, 1}],
          do: Memo.fetch(memo, k, fn -> k end, keep(60_000))

      :ok = Memo.forget_where(memo, &match?({:p, _}, &1))

      assert Memo.peek(memo, {:p, 1}) == :miss
      assert Memo.peek(memo, {:p, 2}) == :miss
      assert Memo.peek(memo, {:q, 1}) == {:ok, {:q, 1}}
    end

    test "reset empties the table and still answers a load in flight", %{memo: memo} do
      me = self()

      load = fn ->
        send(me, {:started, self()})

        receive do
          :go -> :stale
        after
          1_000 -> flunk("the load was never released")
        end
      end

      waiter = Task.async(fn -> Memo.fetch(memo, :k, load, keep(60_000)) end)
      assert_receive {:started, loader}, 1_000
      :ok = Memo.reset(memo)
      send(loader, :go)

      assert Task.await(waiter) == :stale
      assert Memo.peek(memo, :k) == :miss
    end
  end

  describe "newer_than: a refresh joins rather than forgets" do
    # A load that says when it starts and waits to be released, so that what
    # happens while it is in flight is arranged rather than raced.
    defp held(me, result) do
      fn ->
        send(me, {:started, self()})

        receive do
          :go -> result
        after
          1_000 -> flunk("the load was never released")
        end
      end
    end

    # Wait for `n` callers to be parked under `key` in `field`. Polled from
    # the server's state, because a caller parks by sending the server a
    # message and nothing else can say when that message has been taken.
    defp parked(memo, key, field, n) do
      Enum.reduce_while(1..400, :timeout, fn _, _ ->
        case :sys.get_state(memo).loads[key] do
          %{^field => list} when length(list) == n -> {:halt, :ok}
          _ -> Process.sleep(5) && {:cont, :timeout}
        end
      end)
      |> case do
        :ok -> :ok
        :timeout -> flunk("#{n} #{field} never parked under #{inspect(key)}")
      end
    end

    test "two refreshes arriving together share one load", %{memo: memo} do
      me = self()
      opts = [now_ms: 1_000, newer_than: 1_000]

      a = Task.async(fn -> Memo.fetch(memo, :k, held(me, :value), keep(60_000), opts) end)
      assert_receive {:started, loader}, 1_000

      # The second arrives while the first's load is running, asking for a
      # value no older than the moment that load started: it joins it.
      b = Task.async(fn -> Memo.fetch(memo, :k, held(me, :value), keep(60_000), opts) end)
      parked(memo, :k, :waiters, 2)
      refute_received {:started, _}

      send(loader, :go)
      assert Task.await(a) == :value
      assert Task.await(b) == :value
      refute_received {:started, _}
    end

    test "a refresh after a completed load loads again, and stands for the next", %{memo: memo} do
      assert Memo.fetch(memo, :k, fn -> 1 end, keep(60_000), now_ms: 1_000) == 1

      # Loaded at 1_000, which is before 1_001: not good enough.
      assert Memo.fetch(memo, :k, fn -> 2 end, keep(60_000), now_ms: 1_001, newer_than: 1_001) ==
               2

      # Loaded at 1_001, which is good enough for 1_001 and for anything
      # earlier, and not for a moment after it.
      assert Memo.fetch(memo, :k, fn -> 3 end, keep(60_000), now_ms: 1_002, newer_than: 1_001) ==
               2

      assert Memo.fetch(memo, :k, fn -> 3 end, keep(60_000), now_ms: 1_002, newer_than: 500) == 2
      assert Memo.peek(memo, :k, 1_002, 1_001) == {:ok, 2}
      assert Memo.peek(memo, :k, 1_002, 1_002) == :miss
      assert Memo.peek(memo, :k, 1_002) == {:ok, 2}
    end

    test "refreshes arriving during an older load share the one load that follows it", %{
      memo: memo
    } do
      me = self()

      a = Task.async(fn -> Memo.fetch(memo, :k, held(me, :old), keep(60_000), now_ms: 1_000) end)
      assert_receive {:started, first}, 1_000

      # Two pages hearing the same news a moment after the load began. What
      # is running may have asked the provider before the news happened, so
      # neither joins it -- and neither starts one beside it.
      b =
        Task.async(fn ->
          Memo.fetch(memo, :k, held(me, :new), keep(60_000), now_ms: 1_001, newer_than: 1_001)
        end)

      c =
        Task.async(fn ->
          Memo.fetch(memo, :k, held(me, :new), keep(60_000), now_ms: 1_002, newer_than: 1_002)
        end)

      parked(memo, :k, :followers, 2)
      refute_received {:started, _}

      send(first, :go)
      assert Task.await(a) == :old

      # The one load promised to both starts only now, and there is one.
      assert_receive {:started, second}, 1_000
      refute_received {:started, _}
      send(second, :go)
      assert Task.await(b) == :new
      assert Task.await(c) == :new

      # Stamped with the latest follower's clock: good for 1_002 and not
      # claimed to be any newer than that.
      assert Memo.peek(memo, :k, 1_003, 1_002) == {:ok, :new}
      assert Memo.peek(memo, :k, 1_003, 1_003) == :miss
    end

    test "a forget during the older load leaves the follow-up's answer standing", %{memo: memo} do
      me = self()

      a = Task.async(fn -> Memo.fetch(memo, :k, held(me, :old), keep(60_000), now_ms: 1_000) end)
      assert_receive {:started, first}, 1_000

      b =
        Task.async(fn ->
          Memo.fetch(memo, :k, held(me, :new), keep(60_000), now_ms: 1_001, newer_than: 1_001)
        end)

      parked(memo, :k, :followers, 1)
      :ok = Memo.forget(memo, :k)
      send(first, :go)

      # The forgotten load answers its own waiter and writes nothing.
      assert Task.await(a) == :old
      assert Memo.peek(memo, :k, 1_001) == :miss

      # The follow-up began after the forget, so it is not the load the
      # forget was about: its answer is kept.
      assert_receive {:started, second}, 1_000
      send(second, :go)
      assert Task.await(b) == :new
      assert Memo.peek(memo, :k, 1_001) == {:ok, :new}
    end

    test "run: :caller hands the follow-up to a follower to run itself", %{memo: memo} do
      me = self()

      a =
        Task.async(fn ->
          Memo.fetch(memo, :k, held(me, :old), keep(60_000), now_ms: 1_000, run: :caller)
        end)

      assert_receive {:started, first}, 1_000
      assert first == a.pid

      b =
        Task.async(fn ->
          Memo.fetch(memo, :k, held(me, :new), keep(60_000),
            now_ms: 1_001,
            newer_than: 1_001,
            run: :caller
          )
        end)

      parked(memo, :k, :followers, 1)
      send(first, :go)
      assert Task.await(a) == :old

      assert_receive {:started, second}, 1_000
      assert second == b.pid
      send(second, :go)
      assert Task.await(b) == :new
      assert Memo.peek(memo, :k, 1_001, 1_001) == {:ok, :new}
    end
  end

  describe "a crash is an answer" do
    test "a load that raises answers every waiter and is not remembered", %{memo: memo} do
      boom = fn -> raise "no" end
      on_crash = fn reason -> {:error, Exception.message(reason)} end

      assert Memo.fetch(memo, :k, boom, keep(60_000), on_crash: on_crash) == {:error, "no"}
      assert Memo.peek(memo, :k) == :miss
    end

    test "waiters joined to a crashing load are answered too", %{memo: memo} do
      me = self()

      boom = fn ->
        send(me, :started)
        Process.sleep(30)
        raise "no"
      end

      on_crash = fn reason -> {:error, Exception.message(reason)} end
      opts = [on_crash: on_crash]

      tasks =
        for _ <- 1..5, do: Task.async(fn -> Memo.fetch(memo, :k, boom, keep(60_000), opts) end)

      assert Enum.map(tasks, &Task.await/1) == List.duplicate({:error, "no"}, 5)
    end
  end

  describe "run: :caller" do
    test "the load runs in the calling process", %{memo: memo} do
      me = self()
      load = fn -> send(me, {:ran_in, self()}) && :value end

      assert Memo.fetch(memo, :k, load, keep(60_000), run: :caller) == :value
      assert_received {:ran_in, ^me}
    end

    test "a second caller waits rather than running it again", %{memo: memo} do
      me = self()

      slow = fn ->
        send(me, :loaded)
        Process.sleep(50)
        :value
      end

      opts = [run: :caller]
      a = Task.async(fn -> Memo.fetch(memo, :k, slow, keep(60_000), opts) end)
      Process.sleep(10)
      b = Task.async(fn -> Memo.fetch(memo, :k, slow, keep(60_000), opts) end)

      assert Task.await(a) == :value
      assert Task.await(b) == :value
      assert_received :loaded
      refute_received :loaded
    end

    test "a runner that dies answers the waiters parked behind it", %{memo: memo} do
      me = self()

      runner =
        spawn(fn ->
          Memo.fetch(
            memo,
            :k,
            fn ->
              send(me, :claimed)
              Process.sleep(:infinity)
            end,
            keep(60_000),
            run: :caller,
            on_crash: fn _ -> {:error, :runner_died} end
          )
        end)

      assert_receive :claimed, 1_000

      waiter =
        Task.async(fn -> Memo.fetch(memo, :k, fn -> :never end, keep(60_000), run: :caller) end)

      Process.sleep(20)
      Process.exit(runner, :kill)

      assert Task.await(waiter, 1_000) == {:error, :runner_died}
      assert Memo.peek(memo, :k) == :miss
    end

    test "a raising caller re-raises and leaves nothing behind", %{memo: memo} do
      opts = [run: :caller, on_crash: fn _ -> {:error, :crashed} end]

      assert_raise RuntimeError, "no", fn ->
        Memo.fetch(memo, :k, fn -> raise "no" end, keep(60_000), opts)
      end

      assert Memo.peek(memo, :k) == :miss
      # And the key is free: the next caller loads rather than waiting on a
      # claim nobody holds.
      assert Memo.fetch(memo, :k, fn -> :value end, keep(60_000), run: :caller) == :value
    end
  end
end
