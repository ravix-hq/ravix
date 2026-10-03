defmodule Ravix.Repo.Migrations.UseRepositoryProjectNames do
  use Ecto.Migration

  def up do
    # Assumes a small pre-PMF projects table; production MCP is unavailable here.
    # TODO WHEN this update exceeds 5 seconds, move the data update to a batched backfill.
    execute("""
    UPDATE ravix.projects
    SET name = repo_full_name
    WHERE repo_full_name IS NOT NULL AND repo_full_name <> ''
      AND name IS DISTINCT FROM repo_full_name
    """)
  end

  # Full repository names remain valid names for the previous release.
  def down, do: :ok
end
