defmodule Ravix.Health do
  @moduledoc """
  Whether this instance can serve, as opposed to whether it is running.

  One question, asked by `RavixWeb.HealthController` on `/readyz` and therefore
  by Render's health check, which decides whether this instance is in the load
  balancer's rotation (ADR 0003).

  Deliberately not scoped to a user: readiness is a property of the instance,
  the probe is unauthenticated by necessity, and the answer is one bit that
  reveals nothing about anybody's data.
  """

  require Logger

  alias Ecto.Adapters.SQL

  @doc """
  One round trip to the database on a pooled connection.

  `Ecto.Adapters.SQL.query/3` rather than reading a row: readiness must not
  depend on a table existing, on the `ravix` prefix, or on a migration having
  run -- `bin/migrate` runs before the new instances start, and an instance that
  called itself unready because of a schema question would stay out of rotation
  for a reason its operator could not see.
  """
  @spec database?() :: boolean()
  def database? do
    SQL.query!(Ravix.Repo, "SELECT 1", [])
    true
  rescue
    # `query!/3` rather than matching on `{:ok, _}` and `{:error, _}`: a pool
    # with nothing connected *raises* instead of answering, so the bang version
    # collapses both ways of failing into the one path that has to be right.
    # Readiness must answer, never raise -- an exception here would be a 500
    # from the probe, which Render reads as unready anyway but which buries the
    # reason in a stack trace instead of stating it.
    error ->
      Logger.warning("ravix: readiness check failed: #{Exception.message(error)}")
      false
  end
end
