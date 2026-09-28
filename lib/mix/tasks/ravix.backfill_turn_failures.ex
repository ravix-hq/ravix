defmodule Mix.Tasks.Ravix.BackfillTurnFailures do
  @moduledoc """
  Classify historical settled turns once for explicitly selected thread IDs.

      mix ravix.backfill_turn_failures THREAD_ID [THREAD_ID ...]

  Requires the application's configured database and Fountain connection.
  Safe to resume: each turn's completion marker is committed with its correction.
  """
  alias Ravix.Tracks.Settlement
  use Mix.Task
  @shortdoc "Backfill stored transcript failures for selected threads"

  @impl true
  def run([]), do: Mix.raise("Supply at least one thread ID")

  def run(ids) do
    # Not app.start: see `Ravix.Release`, no singletons or endpoint for a task.
    Mix.Task.run("app.config")
    Ravix.Release.start_services()

    Enum.each(ids, fn id ->
      case Settlement.backfill(id) do
        :ok -> Mix.shell().info("Classified thread #{id}")
        {:error, reason} -> Mix.raise("Backfill failed: #{inspect(Ravix.Redact.reason(reason))}")
      end
    end)
  end
end
