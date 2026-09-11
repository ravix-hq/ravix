defmodule Ravix.Sprites.ShapesTest do
  use ExUnit.Case, async: true

  alias Ravix.Sprites.Shapes
  alias Ravix.Sprites.Shapes.Service

  @defined %{
    "name" => "sy-t1",
    "cmd" => "sh",
    "args" => ["-lc", "npm run dev"],
    "dir" => "/work/t1",
    "env" => %{"PORT" => "20123", "HOST" => "127.0.0.1"},
    "state" => %{"status" => "running", "restart_count" => 0}
  }

  describe "service/1" do
    test "reads the definition and the state" do
      assert %Service{
               name: "sy-t1",
               cmd: "sh",
               args: ["-lc", "npm run dev"],
               dir: "/work/t1",
               env: %{"PORT" => "20123", "HOST" => "127.0.0.1"},
               http_port: nil,
               needs: [],
               status: "running",
               restart_count: 0
             } = Shapes.service(@defined)
    end

    test "a service with no state at all is readable, and is not running" do
      service = Shapes.service(%{"name" => "sy-t1"})

      assert %Service{status: nil, restart_count: 0, args: [], needs: [], env: %{}} = service
      refute Shapes.running?(service)
      refute Shapes.crash_looping?(service)
    end

    test "a restart_count that is not a number is zero, not a crash loop" do
      for value <- [nil, "three", %{}] do
        service = Shapes.service(%{"state" => %{"restart_count" => value}})
        assert %Service{restart_count: 0} = service
        refute Shapes.crash_looping?(service)
      end
    end
  end

  describe "running?/1" do
    test "only Sprites' own word for up" do
      for {status, running} <- [
            {"running", true},
            {"stopped", false},
            {"starting", false},
            {"failed", false},
            {nil, false}
          ] do
        assert Shapes.running?(Shapes.service(%{"state" => %{"status" => status}})) == running
      end
    end

    test "a service Sprites has no definition for is not running" do
      refute Shapes.running?(nil)
    end
  end

  describe "crash_looping?/1" do
    test "three restarts is broken, two is slow" do
      for {count, looping} <- [{0, false}, {2, false}, {3, true}, {9, true}] do
        service = Shapes.service(%{"state" => %{"restart_count" => count}})
        assert Shapes.crash_looping?(service) == looping
      end
    end

    test "a service that is not there has not crashed" do
      refute Shapes.crash_looping?(nil)
    end
  end

  describe "defined_as?/4" do
    test "the definition Ravix asked for" do
      assert Shapes.defined_as?(Shapes.service(@defined), "npm run dev", "/work/t1", 20_123)
    end

    test "every way it can be the wrong definition" do
      wrong = [
        {"a different command", %{"args" => ["-lc", "npm start"]}},
        {"a shell that is not sh", %{"cmd" => "bash"}},
        {"a moved directory", %{"dir" => "/work/t2"}},
        {"another track's port", %{"env" => %{"PORT" => "20124", "HOST" => "127.0.0.1"}}},
        {"a host that is not loopback", %{"env" => %{"PORT" => "20123", "HOST" => "0.0.0.0"}}},
        {"an http_port on the machine's public route", %{"http_port" => 8080}},
        {"a dependency Ravix did not ask for", %{"needs" => ["db"]}}
      ]

      for {why, override} <- wrong do
        service = Shapes.service(Map.merge(@defined, override))

        refute Shapes.defined_as?(service, "npm run dev", "/work/t1", 20_123),
               "should have refused #{why}"
      end
    end

    test "a service Sprites has no definition for is not defined as anything" do
      refute Shapes.defined_as?(nil, "npm run dev", "/work/t1", 20_123)
    end
  end
end
