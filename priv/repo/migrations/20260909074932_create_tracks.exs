defmodule Ravix.Repo.Migrations.CreateTracks do
  @moduledoc """
  Tracks and the narrower membership: members, invites, one link, and who
  last read what.
  """
  use Ecto.Migration

  def change do
    create table(:tracks, primary_key: false) do
      add :id, :text, primary_key: true

      add :project_id, references(:projects, type: :text, on_delete: :delete_all), null: false

      add :conversation_id, :text
      add :slug, :text, null: false
      add :title, :text, null: false
      add :branch, :text, null: false
      add :workdir, :text, null: false
      add :origin_kind, :text, null: false
      add :origin_base, :text
      add :origin_number, :integer
      add :origin_title, :text
      add :origin_url, :text
      add :rev, :integer, null: false, default: 1
      add :opened_at, :utc_datetime_usec
      add :closed_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false
      add :created_by_login, :text, null: false
    end

    # One live track per slug per project: the slug is a directory name on a
    # real machine, so two of them is not a naming clash, it is two tracks
    # writing to one worktree.
    create unique_index(:tracks, [:project_id, :slug],
             name: :tracks_slug,
             where: "closed_at IS NULL"
           )

    create index(:tracks, [:project_id, :closed_at], name: :tracks_project)
    create index(:tracks, [:conversation_id], name: :tracks_conversation)

    # Who else is in a track: somebody invited to one worktree gets that
    # worktree and nothing else on the project.
    create table(:track_members, primary_key: false) do
      add :track_id, references(:tracks, type: :text, on_delete: :delete_all), primary_key: true

      add :user_id, references(:users, type: :text, on_delete: :delete_all), primary_key: true

      add :invited_by, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:track_members, [:user_id], name: :track_members_user)

    # Keyed on GitHub's numeric id, not the login; the id is stable and
    # never reused, the login is neither.
    create table(:track_invites, primary_key: false) do
      add :track_id, references(:tracks, type: :text, on_delete: :delete_all), primary_key: true

      add :github_id, :text, primary_key: true
      add :login, :text, null: false
      add :avatar_url, :text
      add :invited_by, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:track_invites, [:github_id], name: :track_invites_github)

    # One link per track, hashed, minting is the revoke.
    create table(:track_links, primary_key: false) do
      add :track_id, references(:tracks, type: :text, on_delete: :delete_all), primary_key: true

      add :token_hash, :text, null: false
      add :created_by, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create unique_index(:track_links, [:token_hash])

    # When each person last looked at each track. Per (track, person),
    # because a shared track is read by more than one pair of eyes.
    create table(:track_reads, primary_key: false) do
      add :track_id, references(:tracks, type: :text, on_delete: :delete_all), primary_key: true

      add :user_id, references(:users, type: :text, on_delete: :delete_all), primary_key: true

      add :seen_at, :utc_datetime_usec, null: false
    end
  end
end
