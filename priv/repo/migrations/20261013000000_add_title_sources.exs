defmodule Ravix.Repo.Migrations.AddTitleSources do
  @moduledoc """
  Who named a track or thread: `auto` when Ravix titled it from its first
  prompt or the runtime's session title, `manual` when a person renamed it,
  nil for the name it opened with. Manual renames win over every automatic
  title (RAV-48).

  Expand only. Two nullable columns, so the release still serving keeps
  writing rows it knows nothing about, and a rename it makes leaves the
  column nil; automatic titling therefore also requires the title it read
  to be the one still stored.
  """
  use Ecto.Migration

  def change do
    alter table(:tracks) do
      add :title_source, :text
    end

    alter table(:threads) do
      add :title_source, :text
    end

    create constraint(:tracks, :tracks_title_source,
             check: "title_source IS NULL OR title_source IN ('auto', 'manual')"
           )

    create constraint(:threads, :threads_title_source,
             check: "title_source IS NULL OR title_source IN ('auto', 'manual')"
           )
  end
end
