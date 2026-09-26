defmodule Ravix.Repo.Migrations.AddSessionScanReceipts do
  use Ecto.Migration

  def change do
    alter table(:prompt_queue) do
      add :session_scan_id, :bigint
    end

    create index(:prompt_queue, [:thread_id, :session_scan_id],
             where: "status = 'sent' AND session_scan_id IS NOT NULL"
           )
  end
end
