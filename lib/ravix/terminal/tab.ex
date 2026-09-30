defmodule Ravix.Terminal.Tab do
  @moduledoc """
  One person's interactive terminal on one track.

  `number` is what the tab is called ("Terminal 2") and is the lowest one
  that person has free on that track, so closing Terminal 1 and opening
  another gives back Terminal 1 rather than Terminal 3. `session_id` is
  Sprites' name for the running shell, filled in when Sprites announces it;
  until then there is nothing to re-attach to, and a tab without one that
  loses its socket is over.

  A tab belongs to the person who opened it and nobody else. Somebody else
  on the same track has their own, on the same machine.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{
          id: String.t() | nil,
          track_id: String.t() | nil,
          user_id: String.t() | nil,
          sprite: String.t() | nil,
          session_id: String.t() | nil,
          number: pos_integer() | nil,
          created_at: DateTime.t() | nil
        }

  schema "terminal_tabs" do
    belongs_to :track, Ravix.Tracks.Track
    belongs_to :user, Ravix.Accounts.User
    field :sprite, :string
    field :session_id, :string
    field :number, :integer
    field :created_at, :utc_datetime_usec
  end

  @doc "A tab. Mints its id and stamps `created_at` when absent."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tab, attrs) do
    tab
    |> cast(attrs, ~w(id track_id user_id sprite session_id number created_at)a)
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required(~w(id track_id user_id sprite number created_at)a)
    |> validate_number(:number, greater_than: 0)
    |> foreign_key_constraint(:track_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:track_id, :user_id, :number])
  end

  @doc "What the tab is called."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{number: number}), do: "Terminal #{number}"
end
