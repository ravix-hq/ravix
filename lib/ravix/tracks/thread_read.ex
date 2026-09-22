defmodule Ravix.Tracks.ThreadRead do
  @moduledoc "A person's read position in one thread."
  use Ecto.Schema
  @primary_key false
  @foreign_key_type :string

  schema "thread_reads" do
    belongs_to :thread, Ravix.Tracks.Thread, primary_key: true
    belongs_to :user, Ravix.Accounts.User, primary_key: true
    field :seen_at, :utc_datetime_usec
  end
end
