defmodule Ravix.Repo.Migrations.AddPromptClaimOwner do
  use Ecto.Migration

  def change do
    alter table(:prompt_queue) do
      add :claimed_by, :text
      add :claim_token, :text
      add :post_started_at, :utc_datetime_usec
    end
  end
end
