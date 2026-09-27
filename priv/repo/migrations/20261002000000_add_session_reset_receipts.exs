defmodule Ravix.Repo.Migrations.AddSessionResetReceipts do
  use Ecto.Migration

  def change do
    alter table(:prompt_queue) do
      add :session_reset_id, :bigint
    end

    create index(:prompt_queue, [:thread_id, :session_reset_id],
             where: "status = 'sent' AND session_reset_id IS NOT NULL"
           )
  end
end
