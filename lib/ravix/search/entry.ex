defmodule Ravix.Search.Entry do
  @moduledoc "Selected conversation text, never the event or attachment payload."
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @type t :: %__MODULE__{}
  schema "search_entries" do
    belongs_to :thread, Ravix.Tracks.Thread
    field :conversation_id, :string
    field :turn_id, :string
    field :kind, :string
    field :text, :string
    field :last_event_id, :integer
    field :occurred_at, :utc_datetime_usec
  end
end
