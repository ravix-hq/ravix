defmodule Ravix.HubTest do
  @moduledoc """
  What goes out on a project's topic, and who has to care about it.

  The routing question is the one worth pinning down. `track_id` is what
  lets a page showing one track drop a sibling's news, and the case that
  must never be dropped is the event that names no track at all: somebody
  added to the whole project, the machine rebuilt, the settings moved.
  Getting that inverted would be silent -- the page would look right until
  the moment somebody's access changed.
  """
  use ExUnit.Case, async: true

  alias Ravix.Hub
  alias Ravix.Hub.Event

  describe "Event.new/3" do
    test "carries the project, and the track when there is one" do
      assert %Event{name: :people, project_id: "p1", track_id: "t1", present: []} =
               Event.new(:people, "p1", track_id: "t1")

      assert %Event{name: :settings, project_id: "p1", track_id: nil} =
               Event.new(:settings, "p1")

      assert %Event{name: :here, present: [%{login: "ana"}]} =
               Event.new(:here, "p1", track_id: "t1", present: [%{login: "ana"}])

      # A read mark names its reader, so a rail can tell its own from
      # everybody else's without asking anything.
      assert %Event{name: :read, track_id: "t1", user_id: "u1"} =
               Event.new(:read, "p1", track_id: "t1", user_id: "u1")

      assert %Event{user_id: nil} = Event.new(:tracks, "p1", track_id: "t1")
    end

    test "refuses a name that is not one of the seven" do
      # The set is closed on purpose: these are written here and never
      # received from outside, so a typo should not become a live event
      # nobody handles.
      assert_raise FunctionClauseError, fn -> Event.new(:peple, "p1") end
      assert_raise FunctionClauseError, fn -> Event.new("people", "p1") end
      assert_raise FunctionClauseError, fn -> Event.new(:people, nil) end

      assert Enum.sort(Event.names()) ==
               [:here, :people, :queue, :read, :settings, :tracks, :turn]
    end
  end

  describe "Event.concerns?/2" do
    test "a named track concerns that track and no other" do
      event = Event.new(:turn, "p1", track_id: "t1")
      assert Event.concerns?(event, "t1")
      refute Event.concerns?(event, "t2")
    end

    test "an event naming no track concerns every page on the project" do
      # The wider claim, and the one a reader must not optimise away: this
      # is how a page finds out that the people it belongs to have changed.
      event = Event.new(:people, "p1")
      assert Event.concerns?(event, "t1")
      assert Event.concerns?(event, "t2")
    end
  end

  describe "publish/3" do
    setup do
      project_id = "project-" <> Integer.to_string(System.unique_integer([:positive]))
      Hub.subscribe(project_id)
      %{project_id: project_id}
    end

    test "reaches a subscriber as a struct", %{project_id: project_id} do
      Hub.publish(project_id, :queue, track_id: "t1")

      assert_receive {:hub, %Event{name: :queue, project_id: ^project_id, track_id: "t1"}}
    end

    test "a subscriber that left hears nothing further", %{project_id: project_id} do
      Hub.unsubscribe(project_id)
      Hub.publish(project_id, :tracks, track_id: "t1")
      refute_receive {:hub, _}, 100
    end

    test "publishing to a topic nobody is on is still :ok" do
      # Best-effort by design: a request never fails because a page closed.
      assert :ok = Hub.publish("nobody-here", :settings)
    end
  end
end
