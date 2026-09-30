defmodule Ravix.Repo.Migrations.AddMemberRoles do
  @moduledoc """
  ADR 0010, expand: a role on each track seat and project membership.

  Nullable with no default, because the release still serving inserts rows
  without it, and NULL reads as `write` -- what every member could do before
  roles existed. So the old release keeps working, and a row it writes during
  the deploy means what it meant. The contract step (backfill NULL to
  `write`, then NOT NULL DEFAULT 'write') ships in a later release, once no
  instance of this one's predecessor is serving.
  """
  use Ecto.Migration

  def change do
    for table <- [:track_members, :project_members] do
      alter table(table) do
        add :role, :text
      end

      create constraint(table, :"#{table}_role",
               check: "role IS NULL OR role IN ('read', 'write', 'admin')"
             )
    end
  end
end
