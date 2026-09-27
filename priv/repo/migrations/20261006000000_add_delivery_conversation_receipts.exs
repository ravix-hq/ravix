defmodule Ravix.Repo.Migrations.AddDeliveryConversationReceipts do
  use Ecto.Migration

  def change do
    alter table(:prompt_queue) do
      add :delivery_conversation_id, :text
    end

    create index(:prompt_queue, [:thread_id, :delivery_conversation_id, :sequence],
             where: "status = 'sent'"
           )
  end
end
