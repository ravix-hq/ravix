defmodule Ravix.Routines.Routine do
  @moduledoc "A personal project prompt admitted by a write-only webhook credential."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "routines" do
    field :resource_id, :string
    field :user_id, :string
    field :project_id, :string
    field :name, :string
    field :prompt, :string
    field :enabled, :boolean, default: true
    field :credential_hash, :string, redact: true
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:name, :prompt, :enabled])
    |> update_change(:name, &trim/1)
    |> update_change(:prompt, &trim/1)
    |> Ravix.Schema.put_new_id()
    |> validate_required([:user_id, :project_id, :name, :prompt, :enabled, :credential_hash])
    |> validate_length(:name, max: 100)
    |> validate_length(:prompt, max: 15_000)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:project_id)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
