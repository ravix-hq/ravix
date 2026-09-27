defmodule Ravix.Repo.Migrations.AddFeedbackCodes do
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :setup_error_code, :text
    end

    alter table(:prompt_queue) do
      add :error_code, :text
    end

    execute """
            UPDATE ravix.prompt_queue SET error_code = 'inference_credential_unusable'
            WHERE error = 'Agent connection unavailable. Reconnect the project owner''s agent, then retry.'
            """,
            "SELECT 1"

    execute """
            UPDATE ravix.tracks SET setup_error_code = 'inference_credential_unusable'
            WHERE setup_error LIKE '%inference_credential_unusable%'
               OR setup_error LIKE '%chatgpt_grant_unusable%'
            """,
            "SELECT 1"
  end
end
