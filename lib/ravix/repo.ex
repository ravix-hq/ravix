defmodule Ravix.Repo do
  use Ecto.Repo,
    otp_app: :ravix,
    adapter: Ecto.Adapters.Postgres
end
