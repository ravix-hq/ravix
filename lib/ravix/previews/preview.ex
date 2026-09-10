defmodule Ravix.Previews.Preview do
  @moduledoc """
  A track's preview: its hostname, and the port it holds on its sprite.

  `row` is the whole preview record as the reconciler sees it (config,
  applied config, desired and actual state, generation, lease, logs, and
  so on), stored as one JSON document because it is read and written as a
  unit. `hostname`, `sprite` and `port` are real columns because the
  database enforces things about them: the hostname is unique, and the
  partial unique index `preview_ports` on `(sprite, port)` where the sprite
  is set owns port allocation, including across connections.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "previews" do
    belongs_to :track, Ravix.Tracks.Track, primary_key: true
    field :hostname, :string
    field :sprite, :string
    field :port, :integer
    field :row, :map
  end

  @fields ~w(track_id hostname sprite port row)a

  @doc "A preview row. A port is only meaningful with a sprite, and the index only guards that case."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(preview, attrs) do
    preview
    |> cast(attrs, @fields)
    |> validate_required([:track_id, :hostname, :row])
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> foreign_key_constraint(:track_id)
    |> unique_constraint(:track_id, name: :previews_pkey)
    |> unique_constraint(:hostname)
    |> unique_constraint([:sprite, :port],
      name: :preview_ports,
      error_key: :port,
      message: "is already taken on this sprite"
    )
  end
end
