defmodule Ravix.CachePropertiesTest do
  # Not async: `MachineCache.reset/0` clears the application's one named
  # `Ravix.MachineCache`, under every other test reading through it.
  use ExUnit.Case, async: false
  use ExUnitProperties
  alias Ravix.{Fountain.FakeTransport, MachineCache}

  property "invalidated callers settle in any completion order without overwriting the latest generation" do
    check all(weights <- list_of(integer(), min_length: 2, max_length: 6), max_runs: 30) do
      client = FakeTransport.client([])
      parent = self()
      key = "generation-#{System.unique_integer([:positive])}"

      loads =
        for {weight, generation} <- Enum.with_index(weights) do
          MachineCache.reset()

          task =
            Task.async(fn ->
              MachineCache.sprite_name(client, key, fn ->
                send(parent, {:started, generation, self()})

                receive do
                  :finish -> "sprite-#{generation}"
                after
                  2_000 -> flunk("loader was never released")
                end
              end)
            end)

          assert_receive {:started, ^generation, loader}
          {weight, generation, task, loader}
        end

      for {_, generation, task, loader} <- Enum.sort_by(loads, &elem(&1, 0)) do
        send(loader, :finish)
        assert Task.await(task) == "sprite-#{generation}"
      end

      expected = "sprite-#{length(weights) - 1}"

      assert MachineCache.sprite_name(client, key, fn -> flunk("latest answer was not cached") end) ==
               expected
    end
  end
end

defmodule Ravix.QueuePropertiesTest do
  use Ravix.DataCase, async: true
  use ExUnitProperties
  alias Ravix.PromptQueue

  property "cancelled and sent prompts remain terminal under replay, restart and late provider responses" do
    user = insert_user()
    track = insert_track(project: insert_project(user: user))

    operations =
      member_of([
        :claim,
        :recover,
        :retry,
        :duplicate,
        :cancel,
        :sending,
        :failed,
        :sent,
        :unconfirmed
      ])

    check all(
            actions <- list_of(operations, min_length: 1, max_length: 30),
            terminal <- member_of([:cancelled, :sent]),
            max_runs: 50
          ) do
      id = Ecto.UUID.generate()
      payload = %{prompt: "Exactly once", images: []}
      assert {:ok, _} = PromptQueue.Store.enqueue(track.id, user.id, user.login, id, payload)

      if terminal == :sent,
        do: PromptQueue.Store.set_status(id, :sent),
        else: PromptQueue.Store.cancel_track(track.id)

      for action <- actions do
        case action do
          :claim ->
            refute PromptQueue.Store.claim(id)

          :recover ->
            PromptQueue.Store.recover()

          :retry ->
            assert {:error, _} = PromptQueue.retry(user, track.id, id)

          :duplicate ->
            assert {:ok, %{id: ^id}} =
                     PromptQueue.Store.enqueue(track.id, user.id, user.login, id, payload)

          :cancel ->
            PromptQueue.Store.cancel_track(track.id)

          status ->
            PromptQueue.Store.set_status(id, status)
        end

        assert %{status: ^terminal, payload: ""} = PromptQueue.Store.get(id)
      end
    end
  end
end

defmodule Ravix.TranscriptPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Ravix.Tracks.Transcript

  property "overlapping snapshots and out-of-order live replay produce the same transcript once" do
    check all(
            chunks <- list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 20),
            weights <- list_of(integer(), length: length(chunks)),
            max_runs: 60
          ) do
      opened = %{
        "id" => 0,
        "turn_id" => "turn",
        "kind" => "stage",
        "stage" => "turn",
        "state" => "started",
        "blocks" => [%{"kind" => "prompt", "body" => "User prompt"}]
      }

      events =
        for {chunk, id} <- Enum.with_index(chunks, 1) do
          data =
            Jason.encode!(%{
              method: "session/update",
              params: %{
                update: %{
                  sessionUpdate: "agent_message_chunk",
                  content: %{type: "text", text: chunk}
                }
              }
            })

          %{
            "id" => id,
            "turn_id" => "turn",
            "kind" => "output",
            "stream" => "acp",
            "data" => data
          }
        end

      expected = Transcript.page([opened | events], "claude")
      shuffled = Enum.zip(weights, events) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

      actual =
        Transcript.page([opened], "claude")
        |> Transcript.add_events(shuffled ++ events ++ shuffled)

      assert actual == expected
      assert [%{prompt: "User prompt", blocks: [%{body: text}]}] = actual.turns
      assert text == Enum.join(chunks)
      assert actual.last_event_id == length(chunks)
    end
  end
end
