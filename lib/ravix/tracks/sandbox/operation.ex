defmodule Ravix.Tracks.Sandbox.Operation do
  @moduledoc """
  Durable intent and cleanup for one track generation. Resource IDs include
  sandbox/vault and, when known, home agent, environment and credential-set
  IDs. Never store credentials or provider payloads here. Old generations
  remain readable until their resources are confirmed cleaned up.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @type t :: %__MODULE__{}

  schema "track_sandbox_operations" do
    belongs_to :track, Ravix.Tracks.Track
    field :generation, :integer
    field :action, Ecto.Enum, values: [:open, :close, :rebuild]
    field :attempts, :integer, default: 0
    field :revision, :integer, default: 1
    field :resource_ids, :map, default: %{}
    field :error, :map
    field :cleanup, :map, default: %{}
    field :completed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @doc "New intent; identity is immutable after insertion."
  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [:track_id, :generation, :action, :resource_ids])
    |> Ravix.Schema.put_new_id()
    |> validate_required([:id, :track_id, :generation, :action])
    |> validate_number(:generation, greater_than: 0)
    |> foreign_key_constraint(:track_id)
    |> unique_constraint([:track_id, :generation, :action])
  end

  @doc "Persist progress without letting an older worker overwrite a newer result."
  def progress_changeset(operation, attrs) do
    operation
    |> cast(attrs, [:attempts, :resource_ids, :error, :cleanup, :completed_at])
    |> validate_required([:attempts, :resource_ids, :cleanup])
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> optimistic_lock(:revision)
  end
end
