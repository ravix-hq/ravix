defmodule Mix.Tasks.Ravix.SeedRaviWorkspace do
  @moduledoc """
  Set up the "Ravi" team workspace (ADR 0009 phase 4a).

      mix ravix.seed_ravi_workspace           # dry run: print the plan
      mix ravix.seed_ravi_workspace --apply   # write it

  What it does, and what it refuses, is on `Ravix.Workspaces.RaviSeed`.
  Idempotent: a second `--apply` changes nothing. In a release, run
  `bin/ravix eval "Ravix.Release.seed_ravi_workspace(true)"`. The output
  holds ids, names, logins and repositories, never a secret.
  """
  use Mix.Task

  alias Ravix.Workspaces.RaviSeed

  @shortdoc "Create the Ravi team workspace and move the ravix-hq projects into it"

  @impl true
  def run(argv) do
    case OptionParser.parse(argv, strict: [apply: :boolean]) do
      {opts, [], []} ->
        Mix.Task.run("app.start")
        report(RaviSeed.run(apply: Keyword.get(opts, :apply, false)))

      _ ->
        Mix.raise("Usage: mix ravix.seed_ravi_workspace [--apply]")
    end
  end

  defp report({:ok, summary}),
    do: Enum.each(RaviSeed.format(summary), fn line -> Mix.shell().info(line) end)

  defp report({:error, reason}),
    do: Mix.raise("Seed refused: " <> RaviSeed.describe_error(reason))
end
