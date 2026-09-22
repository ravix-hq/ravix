defmodule Ravix.Repo.Migrations.ThreadPreviewGrants do
  use Ecto.Migration

  def change do
    # Grants keep their old JSON shape readable while new grants name a thread.
    drop unique_index(:preview_agent_grants, [:track_id])

    create unique_index(
             :preview_agent_grants,
             ["track_id", "(COALESCE(row->>'thread_id', track_id))"],
             name: :preview_agent_grants_thread
           )
  end
end
