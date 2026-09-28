defmodule Mix.Tasks.Ravix.AssignPersonalWorkspaces do
  @moduledoc """
  Put every legacy project (no workspace) into its owner's personal
  workspace.

      mix ravix.assign_personal_workspaces           # dry run: print the plan
      mix ravix.assign_personal_workspaces --apply   # write it

  What it moves, marks and skips is on `Ravix.Workspaces.PersonalAssignment`.
  Idempotent: a second `--apply` changes nothing. It starts the repository
  and not the application, so no singleton starts beside a running server.
  In a release, run `bin/ravix eval "Ravix.Release.assign_personal_workspaces(true)"`.
  The output holds ids, names, logins and repositories, never a secret.
  """
  use Mix.Task

  alias Ravix.Workspaces.PersonalAssignment

  @shortdoc "Move legacy projects into their owners' personal workspaces"
  @requirements ["app.config"]

  @impl true
  def run(argv) do
    case OptionParser.parse(argv, strict: [apply: :boolean]) do
      {opts, [], []} ->
        apply? = Keyword.get(opts, :apply, false)
        summary = Ravix.Release.with_repo_only(fn -> PersonalAssignment.run(apply: apply?) end)
        Enum.each(PersonalAssignment.format(summary), fn line -> Mix.shell().info(line) end)

      _ ->
        Mix.raise("Usage: mix ravix.assign_personal_workspaces [--apply]")
    end
  end
end
