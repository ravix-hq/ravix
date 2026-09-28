defmodule Ravix.Workspaces.ConnectState do
  @moduledoc """
  One "Connect GitHub" round trip in flight (ADR 0009, phase 4b).

  Only a hash is stored: of the nonce the browser carries to GitHub and
  back, together with the workspace, the person and their session. A
  callback with the same nonce for another workspace, person or session
  hashes to a different key and finds nothing. The row is deleted on use and
  refused after fifteen minutes. See `Ravix.Workspaces.Connect`.
  """
  use Ecto.Schema

  @derive {Inspect, except: [:key_hash]}
  @primary_key {:key_hash, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "workspace_connect_states" do
    belongs_to :workspace, Ravix.Workspaces.Workspace
    belongs_to :user, Ravix.Accounts.User
    field :created_at, :utc_datetime_usec
  end
end
