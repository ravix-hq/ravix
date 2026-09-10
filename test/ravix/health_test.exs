defmodule Ravix.HealthTest do
  use Ravix.DataCase, async: true

  @moduletag :capture_log

  describe "database?/0" do
    test "true when the database answers" do
      assert Ravix.Health.database?()
    end

    test "false, rather than raising, when there is no connection to answer on" do
      # A process with no sandbox ownership stands in for a pool that cannot
      # reach the database: Ecto raises there rather than returning an error
      # tuple, and this is the branch that decides whether an instance leaves
      # the rotation or takes the whole endpoint down with it. Plain `spawn`
      # rather than a task, so `$callers` does not lend it the test's connection.
      parent = self()
      spawn(fn -> send(parent, {:ready?, Ravix.Health.database?()}) end)

      assert_receive {:ready?, false}, 5_000
    end
  end
end
