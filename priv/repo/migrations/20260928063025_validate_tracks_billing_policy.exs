defmodule Ravix.Repo.Migrations.ValidateTracksBillingPolicy do
  @moduledoc """
  Validate the check `20260928054856_expand_workspaces` added `NOT VALID`.

  Validation takes a SHARE UPDATE EXCLUSIVE lock, which does not block the
  serving release's reads or writes; `lock_timeout` still bounds the wait.
  Every existing row has a null `billing_policy`, so it cannot fail.
  """
  use Ecto.Migration

  def up do
    execute "SET LOCAL lock_timeout = '5s'"
    execute "ALTER TABLE ravix.tracks VALIDATE CONSTRAINT tracks_billing_policy"
  end

  def down, do: :ok
end
