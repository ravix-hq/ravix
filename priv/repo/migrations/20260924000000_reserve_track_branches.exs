defmodule Ravix.Repo.Migrations.ReserveTrackBranches do
  use Ecto.Migration

  def change do
    # Old PR tracks may share a branch. Preserve every existing row unchanged;
    # new tracks reserve names, and the context also checks historical rows.
    alter table(:tracks) do
      add :branch_reserved, :boolean, null: false, default: false
    end

    create unique_index(:tracks, [:project_id, :branch],
             name: :tracks_branch,
             where: "branch_reserved"
           )
  end
end
