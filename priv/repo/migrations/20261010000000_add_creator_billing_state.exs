defmodule Ravix.Repo.Migrations.AddCreatorBillingState do
  @moduledoc """
  ADR 0009 phase 6, expand only: what a creator-billed track needs besides
  its payer (`docs/creator-billing.md`).

  `billing_pauses` is the harnesses paused on the track because the payer's
  credential stopped serving, keyed by runtime: a reason everybody on the
  track is shown, and when it started. `billing_notice_at` is when the
  creator was told, once, that collaborators' prompts spend their
  subscription. The release still serving while this runs writes neither
  and reads neither, so both default to "nothing yet".
  """
  use Ecto.Migration

  @lock_timeout "SET LOCAL lock_timeout = '5s'"

  def change do
    execute @lock_timeout, "SELECT 1"

    alter table(:tracks) do
      add :billing_pauses, :map, null: false, default: %{}
      add :billing_notice_at, :utc_datetime_usec
    end

    execute "SELECT 1", @lock_timeout
  end
end
