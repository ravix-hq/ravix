defmodule Ravix.Previews.Preview do
  @moduledoc """
  A track's preview: what it is meant to be doing, and where.

  One column per field. It was one `row` jsonb document until the migration
  `PreviewsIntoColumns`, which is the shape `preview-store.ts` kept and which
  made the unit of write the whole record: every writer read nineteen fields,
  changed one, and wrote nineteen back, so a commit that landed in between
  was reverted. `Ravix.Previews.touch/1` still carries the comment about what
  that cost. With columns a writer sets the field it owns.

  The database holds what it can guarantee: `hostname` is unique, the partial
  unique index `preview_ports` on `(sprite, port)` where the sprite is set
  owns port allocation across connections, and `desired` and `state` are
  `CHECK`-constrained to their sets so `Ecto.Enum` can raise on a value that
  should not exist rather than coerce it.

  `config` is the one map left on disk, and is a map because it is one value:
  nil, or a complete `{directory, command, readiness_path}` the track
  overrides the project default with. In memory it is a
  `Ravix.Previews.Config`, through `Ravix.Previews.Config.Type`.

  `generation`, `last_activity`, `lease_until` and `started_at` are
  milliseconds since the epoch, which is what `Ravix.Clock` answers.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  @desired ~w(running stopped)a
  @states ~w(stopped starting ready failed)a

  schema "previews" do
    belongs_to :track, Ravix.Tracks.Track, primary_key: true
    field :hostname, :string
    field :service, :string
    field :sprite, :string
    field :port, :integer
    field :sandbox_id, :string
    field :config, Ravix.Previews.Config.Type
    field :applied_config, :string
    field :desired, Ecto.Enum, values: @desired, default: :stopped
    field :state, Ecto.Enum, values: @states, default: :stopped
    field :generation, :integer, default: 0
    field :last_activity, :integer, default: 0
    field :lease_until, :integer, default: 0
    field :started_at, :integer, default: 0
    field :error, :string
    field :logs, :string, default: ""
    field :cleanup, :boolean, default: false
    field :stop_pending, :boolean, default: false
    field :unavailable, :string

    # Expand phase. The columns above are the record; this is the document
    # they came out of, still written so a release that reads it keeps
    # working until it is gone. The migration that drops the column takes
    # this field with it.
    field :row, :map
  end

  @fields ~w(track_id hostname service sprite port sandbox_id config applied_config
             desired state generation last_activity lease_until started_at error logs
             cleanup stop_pending unavailable row)a

  @doc "The two words `desired` may be, in the order the reconciler reads them."
  @spec desired_states() :: [atom()]
  def desired_states, do: @desired

  @doc "The four words `state` may be."
  @spec states() :: [atom()]
  def states, do: @states

  @doc "A preview row. A port is only meaningful with a sprite, and the index only guards that case."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(preview, attrs) do
    preview
    |> cast(attrs, @fields)
    |> validate_required([:track_id, :hostname, :service, :desired, :state])
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
