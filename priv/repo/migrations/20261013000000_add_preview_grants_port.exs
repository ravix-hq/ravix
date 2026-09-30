defmodule Ravix.Repo.Migrations.AddPreviewGrantsPort do
  @moduledoc """
  The machine port a preview grant admits its holder to, or NULL for the
  track's own run script (RAV-51).

  A grant with a port is minted only after the server has seen that port
  listening on the track's machine, and the gateway admits it only on the
  host for that same port. Nullable and without a default, so the release
  still serving keeps inserting grants exactly as before: every grant it
  writes is a run-script grant, which is what NULL means. Expand only.
  """
  use Ecto.Migration

  def change do
    alter table(:preview_grants) do
      add :port, :integer
    end
  end
end
