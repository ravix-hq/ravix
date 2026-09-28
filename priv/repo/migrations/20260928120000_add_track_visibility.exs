defmodule Ravix.Repo.Migrations.AddTrackVisibility do
  use Ecto.Migration

  def up do
    alter table(:tracks) do
      add :visibility, :text, null: false, default: "project"
      add :created_by, references(:users, type: :text, on_delete: :nilify_all)
    end

    create constraint(:tracks, :tracks_visibility, check: "visibility IN ('project', 'private')")

    execute """
    UPDATE ravix.tracks t SET created_by = u.id
    FROM ravix.users u WHERE lower(t.created_by_login) = lower(u.login)
    AND (SELECT count(*) FROM ravix.users x WHERE lower(x.login) = lower(u.login)) = 1
    """
  end

  def down do
    drop constraint(:tracks, :tracks_visibility)

    alter table(:tracks) do
      remove :visibility
      remove :created_by
    end
  end
end
