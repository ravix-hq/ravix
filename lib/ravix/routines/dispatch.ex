defmodule Ravix.Routines.Dispatch do
  @moduledoc "Durable delivery identity and outcome; never stores the external event body."
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "routine_dispatches" do
    field :routine_id, :string
    field :request_id, :string
    field :payload_hash, :string
    field :status, :string, default: "dispatching"
    field :track_id, :string
    timestamps(type: :utc_datetime_usec)
  end
end
