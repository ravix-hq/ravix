defmodule Mix.Tasks.Ravix.RetitleTracks do
  @moduledoc """
  Title the open tracks automatic titles never reached, which are still
  called by their branch (RAV-83).

      mix ravix.retitle_tracks           # dry run: print the plan
      mix ravix.retitle_tracks --apply   # write it

  What it titles and leaves alone is on `Ravix.Tracks.TitleBackfill`.
  Idempotent, and a rename always wins. It starts the repository and not the
  application. In a release, run
  `bin/ravix eval "Ravix.Release.retitle_tracks(true)"`. The output holds
  ids and outcomes, never a title.
  """
  use Mix.Task

  alias Ravix.Tracks.TitleBackfill

  @shortdoc "Title open tracks still called by their branch"
  @requirements ["app.config"]

  @impl true
  def run(argv) do
    case OptionParser.parse(argv, strict: [apply: :boolean]) do
      {opts, [], []} ->
        apply? = Keyword.get(opts, :apply, false)
        summary = Ravix.Release.with_repo_only(fn -> TitleBackfill.run(apply: apply?) end)
        Enum.each(TitleBackfill.format(summary), fn line -> Mix.shell().info(line) end)

      _ ->
        Mix.raise("Usage: mix ravix.retitle_tracks [--apply]")
    end
  end
end
