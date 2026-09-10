defmodule Ravix.Repo do
  use Ecto.Repo,
    otp_app: :ravix,
    adapter: Ecto.Adapters.Postgres

  alias Ecto.Adapters.SQL

  @impl true
  def default_options(_operation), do: [prefix: "ravix"]

  def prepare_schema(repo) do
    SQL.query!(repo, "CREATE SCHEMA IF NOT EXISTS ravix", [])
    :ok
  end
end
