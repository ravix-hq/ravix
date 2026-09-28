defmodule Mix.Tasks.Ravix.SharingCutover do
  @moduledoc """
  Retire track invitations and links for workspace sharing (ADR 0009 phase 5).

      mix ravix.sharing_cutover           # dry run: print the plan
      mix ravix.sharing_cutover --apply   # write it

  What it does is on `Ravix.People.Cutover`. Refused unless
  `RAVIX_WORKSPACE_ACCESS` is on. Idempotent: a second `--apply` changes
  nothing. In a release, run
  `bin/ravix eval "Ravix.Release.sharing_cutover(true)"`. The output holds
  ids, track titles and logins, never a secret.
  """
  use Mix.Task

  alias Ravix.People.Cutover

  @shortdoc "Turn workspace members' track seats into permission rows and retire invite links"

  @impl true
  def run(argv) do
    case OptionParser.parse(argv, strict: [apply: :boolean]) do
      {opts, [], []} ->
        # Not app.start: see `Ravix.Release`, no singletons or endpoint for a task.
        Mix.Task.run("app.config")
        Ravix.Release.start_services()
        report(Cutover.run(apply: Keyword.get(opts, :apply, false)))

      _ ->
        Mix.raise("Usage: mix ravix.sharing_cutover [--apply]")
    end
  end

  defp report({:ok, summary}),
    do: Enum.each(Cutover.format(summary), fn line -> Mix.shell().info(line) end)

  defp report({:error, :switch_off}),
    do: Mix.raise("Cutover refused: RAVIX_WORKSPACE_ACCESS is off.")
end
