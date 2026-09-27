defmodule Ravix.Tracks.TurnFailure do
  @moduledoc "A durable local correction to an upstream turn outcome, including setup stage evidence."
  use Ecto.Schema
  @primary_key false
  schema "track_turn_failures" do
    field :conversation_id, :string, primary_key: true
    field :turn_id, :string, primary_key: true
    field :stage, :string, primary_key: true
    field :state, :string, default: "failed"
    field :code, :string
    field :reason, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
