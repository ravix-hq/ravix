defmodule Ravix.Repo.Migrations.AddTrackSandboxAction do
  use Ecto.Migration

  # Expand only; both columns are null on every row the previous release
  # wrote, and that release neither reads nor writes them.
  #
  # `sandbox_state` is `provisioning` for an open and a rebuild alike;
  # `sandbox_action` names which lifecycle action wrote it, and null reads as
  # an open. `sandbox_suspended_at` is when Fountain last said a dedicated
  # track's sandbox went to sleep, cleared when a turn starts on it again.
  def change do
    alter table(:tracks) do
      add :sandbox_action, :string
      add :sandbox_suspended_at, :utc_datetime_usec
    end

    create constraint(:tracks, :tracks_sandbox_action,
             check: "sandbox_action IS NULL OR sandbox_action IN ('open', 'close', 'rebuild')"
           )
  end
end
