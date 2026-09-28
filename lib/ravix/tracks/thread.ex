defmodule Ravix.Tracks.Thread do
  @moduledoc "A conversation sharing its track's branch and working directory."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @type t :: %__MODULE__{}

  schema "threads" do
    belongs_to :track, Ravix.Tracks.Track
    field :conversation_id, :string
    field :previous_conversation_ids, {:array, :string}, default: []
    field :credential_recovery, :map
    field :recovery_context_pending, :boolean, default: false
    field :runtime, :string
    field :model, :string
    field :title, :string
    field :created_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    # ADR 0009, expand only: who started the thread, for `Co-authored-by`.
    # Attribution, never billing -- the track's creator pays (see
    # `Ravix.Tracks.Track.payer/2`). Unwritten yet; nil is an unknown starter.
    field :started_by, :string
  end

  @title_length 40

  @doc """
  A title from a thread's first prompt: one line, about forty characters,
  cut at a word boundary. A prompt with no words (an image on its own) is
  "New thread".
  """
  @spec title_from(String.t() | nil) :: String.t()
  def title_from(prompt) when is_binary(prompt) do
    line = prompt |> String.split() |> Enum.join(" ")

    cond do
      line == "" ->
        "New thread"

      String.length(line) <= @title_length ->
        line

      true ->
        cut = String.slice(line, 0, @title_length + 1)

        words =
          case String.split(cut, " ") do
            [_single] -> String.slice(cut, 0, @title_length)
            parts -> parts |> Enum.drop(-1) |> Enum.join(" ")
          end

        String.trim_trailing(words) <> "…"
    end
  end

  def title_from(_prompt), do: "New thread"

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [
      :id,
      :track_id,
      :conversation_id,
      :title,
      :created_at,
      :closed_at,
      :runtime,
      :model,
      :started_by
    ])
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required([:id, :track_id, :title, :created_at])
    |> validate_length(:title, min: 1, max: 200)
    |> foreign_key_constraint(:track_id)
    |> unique_constraint(:conversation_id)
    |> unique_constraint(:id, name: :threads_pkey)
  end
end
