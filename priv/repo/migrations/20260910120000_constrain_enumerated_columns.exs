defmodule Ravix.Repo.Migrations.ConstrainEnumeratedColumns do
  @moduledoc """
  Two columns with a fixed set of values, said in the database.

  `tracks.origin_kind` is one of four and `oauth_states.kind` is one of
  three, and both were `text` accepting anything. The application has always
  written one of the set -- `Ravix.Tracks.read_origin/2` coerces a kind it
  does not recognise to `blank` before it ever reaches a row -- so nothing
  here changes what is stored. What it changes is who guarantees it: a
  `CHECK` means the read side can stop coercing a second time and can be a
  typed `Ecto.Enum` instead, which raises on a value that should not exist
  rather than quietly calling it `blank`.

  Safe to run while the previous release is still serving (expand/contract):
  that release cannot write a value these constraints reject. The `UPDATE`
  before each one is for a row that predates the coercion; on a database
  where there is none, it touches nothing.
  """
  use Ecto.Migration

  @origin_kinds ~w(blank branch pr issue)
  @oauth_kinds ~w(signin install join)

  def up do
    normalise(:tracks, :origin_kind, @origin_kinds, "blank")
    normalise(:oauth_states, :kind, @oauth_kinds, "signin")

    create constraint(:tracks, :tracks_origin_kind, check: in_check("origin_kind", @origin_kinds))
    create constraint(:oauth_states, :oauth_states_kind, check: in_check("kind", @oauth_kinds))
  end

  def down do
    drop constraint(:tracks, :tracks_origin_kind)
    drop constraint(:oauth_states, :oauth_states_kind)
  end

  # Anything outside the set becomes the neutral member, which is what the
  # read side was already doing with it.
  defp normalise(table, column, allowed, fallback) do
    execute("""
    UPDATE #{prefix()}.#{table}
       SET #{column} = '#{fallback}'
     WHERE #{column} NOT IN (#{quoted(allowed)})
    """)
  end

  defp in_check(column, allowed), do: "#{column} IN (#{quoted(allowed)})"
  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
