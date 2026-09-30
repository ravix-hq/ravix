defmodule Ravix.Repo.Migrations.AddTrackRepositories do
  use Ecto.Migration

  # RAV-76, expand only: the repository a track is a branch of, written when
  # its project changes repository so the track's pull request and checks
  # are still looked up where its branch is. Nil means "the project's", which
  # is every track until a change and every track the previous release
  # writes; that release neither reads nor writes these.
  def change do
    alter table(:tracks) do
      add :repo_full_name, :string
      add :repo_installation_id, :bigint
    end
  end
end
