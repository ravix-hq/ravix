defmodule Ravix.Repo.Migrations.AddCredentialSetToProjects do
  @moduledoc """
  Which of its owner's credential sets a project's agent points at.

  Fountain holds the truth of it, on the agent. The column is a note of what
  Ravix last told Fountain, so that `Ravix.Projects.Machine.adopt_credentials/2`
  can answer "is this agent already on its owner's set" with a comparison on
  every wake rather than a call. Nil is an agent on the deployment's default,
  which is what every project that exists today is, so there is nothing to
  backfill.

  Nullable and unread by the previous release, so it is safe to run while that
  release is still serving (expand/contract).
  """
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :credential_set_id, :text
    end
  end
end
