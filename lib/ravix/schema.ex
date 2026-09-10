defmodule Ravix.Schema do
  @moduledoc """
  What every table here has in common.

  Primary keys are strings the application mints, never the database: the
  TypeScript generated UUIDs in the caller, and a track's id travels into its
  branch name before the row exists. Timestamps that were ISO-8601 text are
  `:utc_datetime_usec`; the two millisecond integers the previews compare
  with `Date.now()` stay integers. These two helpers are the changeset side
  of that: fill an id and a creation time the caller did not bring.
  """
  import Ecto.Changeset

  @doc "A fresh UUID for `field` when the caller did not supply one."
  @spec put_new_id(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def put_new_id(changeset, field \\ :id) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, Ecto.UUID.generate())
      _ -> changeset
    end
  end

  @doc """
  Now, for `field`, unless a value was given.

  The TypeScript wrote `new Date().toISOString()` at insert time; here the
  changeset does it, so a context can insert without naming the clock.
  """
  @spec stamp(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def stamp(changeset, field) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, DateTime.utc_now())
      _ -> changeset
    end
  end
end
