defmodule Ravix.Repo.Migrations.AddOnboardingToUsers do
  @moduledoc """
  What a person chose on their first visit, and that they have had one.

  Until now every machine ran on the deployment's own Fountain credentials, so
  there was nothing about a person to remember beyond who they are. Now each
  person brings their own Claude or Codex subscription:

    * `agent` is which of the two they picked, `claude` or `codex`. It is the
      runtime a project of theirs is built with.
    * `credential_set_id` is the Fountain inference credential set holding
      their subscription token or API key. The value itself is never here: it
      goes to Fountain and cannot be read back.
    * `credential_kind` is which of those two it was, `subscription` or
      `api_key`, so the page can say what is connected without asking Fountain.
    * `onboarded_at` is when they finished, or dismissed, the first-run
      walkthrough.

  All four are nullable and nothing reads them as required, so this is safe to
  run while the previous release is still serving (expand/contract): that
  release neither writes them nor selects them by name. Nobody is backfilled.
  Somebody who already has a project is never sent to the walkthrough, because
  the page asks that question of their projects rather than of this column.
  """
  use Ecto.Migration

  @agents ~w(claude codex)
  @kinds ~w(subscription api_key)

  def change do
    alter table(:users) do
      add :agent, :text
      add :credential_set_id, :text
      add :credential_kind, :text
      add :onboarded_at, :utc_datetime_usec
    end

    create constraint(:users, :users_agent, check: in_check("agent", @agents))
    create constraint(:users, :users_credential_kind, check: in_check("credential_kind", @kinds))
  end

  defp in_check(column, allowed) do
    "#{column} IS NULL OR #{column} IN (#{Enum.map_join(allowed, ", ", &"'#{&1}'")})"
  end
end
