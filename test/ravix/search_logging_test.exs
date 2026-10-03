defmodule Ravix.SearchLoggingTest do
  use Ravix.DataCase, async: false
  alias Ecto.Adapters.SQL
  alias Ravix.Search.{Entry, Index}
  alias Ravix.TranscriptFixture, as: TF

  setup do
    owner = insert_user()
    project = insert_project(user: owner)
    track = insert_track(project: project, conversation_id: "log-" <> project.id)
    %{track: track}
  end

  defp events(id, human, assistant) do
    [
      TF.stage(1, "started")
      |> Map.merge(%{"turn_id" => id, "blocks" => [%{"kind" => "prompt", "body" => human}]}),
      TF.output(2, TF.text(assistant), id),
      TF.stage(3, "completed") |> Map.put("turn_id", id)
    ]
  end

  test "selected conversation text is persisted without Ecto debug log params", ctx do
    human = "human-sensitive-" <> Ecto.UUID.generate()
    assistant = "assistant-sensitive-" <> Ecto.UUID.generate()

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        %{level: level} = :logger.get_primary_config()
        :logger.set_primary_config(:level, :debug)

        try do
          SQL.query!(Repo, "SELECT $1::text", ["search-log-control"])

          Index.record(
            ctx.track.conversation_id,
            events("private-log", human, assistant),
            "claude"
          )
        after
          :logger.set_primary_config(:level, level)
        end
      end)

    assert log =~ "search-log-control"
    refute log =~ human
    refute log =~ assistant
    assert Enum.sort(Enum.map(Repo.all(Entry), & &1.kind)) == ["assistant", "prompt"]
  end
end
