defmodule Mix.Tasks.Ravix.PrepareDatabase do
  @moduledoc "Creates the schema reserved for the Elixir application."
  use Mix.Task
  @shortdoc "Create Ravix's isolated database schema"
  @requirements ["app.config"]

  @impl true
  def run(_args) do
    {:ok, _, _} = Ecto.Migrator.with_repo(Ravix.Repo, &Ravix.Repo.prepare_schema/1)
  end
end
