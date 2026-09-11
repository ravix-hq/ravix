defmodule Ravix.Fountain.ShapesTest do
  use ExUnit.Case, async: true

  alias Ravix.Fountain.Shapes
  alias Ravix.Fountain.Shapes.{Conversation, Sandbox, Turn}

  describe "conversation/1" do
    test "reads the fields the rest of Ravix asks for" do
      conversation =
        Shapes.conversation(%{
          "id" => "c1",
          "status" => "running",
          "sandbox_id" => "sb-1",
          "inserted_at" => "2026-09-08T00:00:00Z",
          "last_active_at" => "2026-09-09T10:00:00Z",
          "turn_count" => 4
        })

      assert %Conversation{
               id: "c1",
               status: :running,
               sandbox_id: "sb-1",
               sprite_name: nil,
               inserted_at: "2026-09-08T00:00:00Z",
               last_active_at: ~U[2026-09-09 10:00:00Z],
               turn_count: 4
             } = conversation
    end

    test "a conversation Fountain said nothing about is every field absent, not a crash" do
      assert %Conversation{
               id: nil,
               status: :other,
               sandbox_id: nil,
               sprite_name: nil,
               inserted_at: nil,
               last_active_at: nil,
               turn_count: nil
             } = Shapes.conversation(%{})
    end

    test "a status this version does not know is :other, and no atom is created" do
      # Not a count of the atom table: the suite is async and another test
      # creating an atom would fail this one. The claim is about this word.
      word = "quiescent_#{System.unique_integer([:positive])}"

      assert %Conversation{status: :other} = Shapes.conversation(%{"status" => word})
      assert %Conversation{status: :other} = Shapes.conversation(%{"status" => "archived"})

      assert_raise ArgumentError, fn -> String.to_existing_atom(word) end
    end

    test "every status Fountain has a word for" do
      for {word, status} <- [
            {"pending", :pending},
            {"idle", :idle},
            {"running", :running},
            {"failed", :failed},
            {"terminated", :terminated}
          ] do
        assert %Conversation{status: ^status} = Shapes.conversation(%{"status" => word})
      end
    end

    test "a last_active_at that is not a time is no time, rather than a wrong comparison" do
      for value <- ["not a date", "", 1_234, nil] do
        assert %Conversation{last_active_at: nil} =
                 Shapes.conversation(%{"last_active_at" => value})
      end
    end

    test "turn_count keeps nil apart from zero" do
      assert %Conversation{turn_count: nil} = Shapes.conversation(%{})
      assert %Conversation{turn_count: 0} = Shapes.conversation(%{"turn_count" => 0})
    end

    test "the detail endpoint's embedded sandbox carries the sprite; the list's null does not" do
      assert %Conversation{sprite_name: "sp-1"} =
               Shapes.conversation(%{"sandbox" => %{"id" => "sb-1", "sprite_name" => "sp-1"}})

      assert %Conversation{sprite_name: nil} =
               Shapes.conversation(%{"sandbox_id" => "sb-1", "sandbox" => nil})
    end
  end

  describe "live?/1, busy?/1 and ended?/1" do
    test "the three questions Ravix asks, over the whole vocabulary" do
      #        status        live?  busy?  ended?
      table = [
        {:pending, true, true, false},
        {:idle, true, false, false},
        {:running, true, true, false},
        {:failed, false, false, true},
        {:terminated, false, false, true},
        {:other, false, false, false}
      ]

      for {status, live, busy, ended} <- table do
        conversation = %Conversation{
          id: "c",
          status: status,
          sandbox_id: nil,
          sprite_name: nil,
          inserted_at: nil,
          last_active_at: nil,
          turn_count: nil
        }

        assert Shapes.live?(conversation) == live, "live?/1 on #{status}"
        assert Shapes.busy?(conversation) == busy, "busy?/1 on #{status}"
        assert Shapes.ended?(conversation) == ended, "ended?/1 on #{status}"
      end
    end

    test "idle is live but not busy: it is what a queued prompt waits for" do
      idle = Shapes.conversation(%{"status" => "idle"})
      assert Shapes.live?(idle)
      refute Shapes.busy?(idle)
    end
  end

  describe "newest/1" do
    test "the latest inserted_at wins" do
      conversations =
        Shapes.conversations([
          %{"id" => "old", "inserted_at" => "2026-09-01T00:00:00Z"},
          %{"id" => "new", "inserted_at" => "2026-09-09T00:00:00Z"},
          %{"id" => "mid", "inserted_at" => "2026-09-08T00:00:00Z"}
        ])

      assert %Conversation{id: "new"} = Shapes.newest(conversations)
    end

    test "one without an inserted_at sorts last rather than crashing the comparison" do
      conversations =
        Shapes.conversations([
          %{"id" => "undated"},
          %{"id" => "dated", "inserted_at" => "2026-01-01T00:00:00Z"}
        ])

      assert %Conversation{id: "dated"} = Shapes.newest(conversations)

      assert %Conversation{id: "undated"} =
               Shapes.newest(Shapes.conversations([%{"id" => "undated"}]))
    end

    test "nothing is nil" do
      assert Shapes.newest([]) == nil
    end
  end

  describe "turn/1" do
    test "reads the prompt and what became of it" do
      assert %Turn{
               id: "t1",
               prompt: "hi",
               origin: "api",
               status: "done",
               inserted_at: "2026-09-09T00:00:00Z"
             } =
               Shapes.turn(%{
                 "id" => "t1",
                 "prompt" => "hi",
                 "origin" => "api",
                 "status" => "done",
                 "inserted_at" => "2026-09-09T00:00:00Z"
               })
    end

    test "a numbered turn is keyed as a string, because the transcript keys on it" do
      assert %Turn{id: "17"} = Shapes.turn(%{"id" => 17})
    end

    test "a field that is not a string is nothing, not a coerced something" do
      assert %Turn{prompt: nil, origin: nil, status: nil, inserted_at: nil} =
               Shapes.turn(%{"id" => "t", "prompt" => 5, "origin" => %{}, "status" => ["x"]})
    end
  end

  describe "sandbox/1" do
    test "the sprite, or nothing" do
      assert %Sandbox{id: "sb-1", sprite_name: "sp-1"} =
               Shapes.sandbox(%{"id" => "sb-1", "sprite_name" => "sp-1"})

      assert %Sandbox{id: nil, sprite_name: nil} = Shapes.sandbox(%{})
    end
  end
end
