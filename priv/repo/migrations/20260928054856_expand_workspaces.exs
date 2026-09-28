defmodule Ravix.Repo.Migrations.ExpandWorkspaces do
  @moduledoc """
  ADR 0009 phase 2: workspaces, expand only.

  Everything here is new or nullable, so the release that is still serving
  while this runs keeps inserting exactly the rows it always did: its
  projects, tracks and threads arrive with every column below null, and the reader
  treats a null workspace as the legacy layout rather than a default one.
  Nothing reads these to authorize yet. `Ravix.Workspaces.Backfill` fills
  the personal workspaces and the equivalent project fields afterwards, in
  resumable batches, and again for whatever an old writer inserted since.

  The `ALTER TABLE`s take brief exclusive locks on `projects`, `tracks` and `threads`
  while the old release serves them, so the transaction gives up after
  `lock_timeout` rather than queueing every request behind a long reader.
  It is set at both ends so it applies first whichever way this runs.
  The track billing check is added `NOT VALID` (new writes are still checked)
  and validated by `20260928063025_validate_tracks_billing_policy`, which does
  not block writes.
  """
  use Ecto.Migration

  @lock_timeout "SET LOCAL lock_timeout = '5s'"

  def change do
    execute @lock_timeout, "SELECT 1"

    # A named team, or the one personal workspace a user starts in. Not the
    # track's working directory, which ADR 0006 also calls a workspace.
    create table(:workspaces, primary_key: false) do
      add :id, :text, primary_key: true
      add :name, :text, null: false
      add :kind, :text, null: false
      # Set only on a personal workspace, and the backfill's idempotency key.
      add :personal_user_id, references(:users, type: :text, on_delete: :delete_all)
      add :created_by_user_id, references(:users, type: :text, on_delete: :nilify_all)
      add :created_at, :utc_datetime_usec, null: false
      add :archived_at, :utc_datetime_usec
    end

    create constraint(:workspaces, :workspaces_kind,
             check:
               "(kind = 'personal' AND personal_user_id IS NOT NULL) OR " <>
                 "(kind = 'team' AND personal_user_id IS NULL)"
           )

    create unique_index(:workspaces, [:personal_user_id],
             name: :workspaces_personal_user,
             where: "personal_user_id IS NOT NULL"
           )

    # Revocation is a timestamp, not a delete: a removed member must stay
    # distinguishable from somebody who was never admitted.
    create table(:workspace_memberships, primary_key: false) do
      add :workspace_id, references(:workspaces, type: :text, on_delete: :delete_all),
        primary_key: true

      add :user_id, references(:users, type: :text, on_delete: :delete_all), primary_key: true
      add :role, :text, null: false
      add :invited_by_user_id, references(:users, type: :text, on_delete: :nilify_all)
      add :created_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
    end

    create constraint(:workspace_memberships, :workspace_memberships_role,
             check: "role IN ('owner', 'admin', 'member')"
           )

    create index(:workspace_memberships, [:user_id], name: :workspace_memberships_user)

    # An explicit, separately authorized connection of a GitHub App
    # installation to a workspace. Knowing an installation id is not one.
    create table(:workspace_installations, primary_key: false) do
      add :id, :text, primary_key: true

      add :workspace_id, references(:workspaces, type: :text, on_delete: :delete_all), null: false

      add :installation_id, :bigint, null: false
      add :account_login, :text
      add :connected_by_user_id, references(:users, type: :text, on_delete: :nilify_all)
      add :connected_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
    end

    create unique_index(:workspace_installations, [:workspace_id, :installation_id],
             name: :workspace_installations_workspace_installation
           )

    create index(:workspace_installations, [:installation_id],
             name: :workspace_installations_installation
           )

    alter table(:projects) do
      add :workspace_id, references(:workspaces, type: :text, on_delete: :nothing)
      # Attribution only: the legacy owner stays `user_id` during compatibility.
      add :created_by_user_id, references(:users, type: :text, on_delete: :nilify_all)
      add :normalized_repo_full_name, :text
      add :github_repo_id, :bigint

      add :workspace_installation_id,
          references(:workspace_installations, type: :text, on_delete: :nothing)

      # Set only by a reviewed migration, never by a client.
      add :legacy_duplicate_of, references(:projects, type: :text, on_delete: :nilify_all)
      add :legacy_duplicate_at, :utc_datetime_usec
    end

    # One project per repository per workspace, over the rows the catalog
    # will admit: legacy (workspace-less) rows, scratch projects and marked
    # legacy duplicates are outside it, so existing duplicates cannot block it.
    create unique_index(:projects, [:workspace_id, :normalized_repo_full_name],
             name: :projects_workspace_repo,
             where:
               "workspace_id IS NOT NULL AND normalized_repo_full_name IS NOT NULL " <>
                 "AND legacy_duplicate_at IS NULL"
           )

    create index(:projects, [:workspace_id], name: :projects_workspace)

    # What survives a legacy duplicate's eventual deletion, so the old
    # creation path cannot quietly create it again. `reserved_project_id` has
    # no foreign key on purpose: it names a project that may be gone.
    create table(:workspace_repository_reservations, primary_key: false) do
      add :id, :text, primary_key: true
      add :normalized_repo_full_name, :text, null: false
      add :workspace_id, references(:workspaces, type: :text, on_delete: :delete_all)
      # The legacy owner whose creation path is reserved, when no workspace is.
      add :user_id, references(:users, type: :text, on_delete: :delete_all)
      add :reserved_project_id, :text, null: false

      add :canonical_project_id,
          references(:projects, type: :text, on_delete: :nilify_all)

      add :reason, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    reservations = :workspace_repository_reservations
    reason = "reason IN ('legacy_duplicate')"
    scope = "workspace_id IS NOT NULL OR user_id IS NOT NULL"
    create constraint(reservations, :workspace_repository_reservations_reason, check: reason)
    create constraint(reservations, :workspace_repository_reservations_scope, check: scope)

    create unique_index(:workspace_repository_reservations, [:reserved_project_id],
             name: :workspace_repository_reservations_project
           )

    create index(:workspace_repository_reservations, [:normalized_repo_full_name],
             name: :workspace_repository_reservations_repo
           )

    # Who started a thread: attribution for `Co-authored-by`, never a payer.
    alter table(:threads) do
      add :started_by, references(:users, type: :text, on_delete: :nilify_all)
    end

    # Who pays for a track's inference (RAV-17 as clarified: the track's
    # creator, bound to its sandbox, for every thread on it). `created_by` is
    # already the creator. Unwritten until creator billing (phase 6); a null
    # policy is a legacy track its project owner pays for.
    alter table(:tracks) do
      add :payer_user_id, references(:users, type: :text, on_delete: :nilify_all)
      add :billing_policy, :text
    end

    create constraint(:tracks, :tracks_billing_policy,
             check: "billing_policy IS NULL OR billing_policy IN ('legacy_owner', 'starter')",
             validate: false
           )

    execute "SELECT 1", @lock_timeout
  end
end
