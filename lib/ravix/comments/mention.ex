defmodule Ravix.Comments.Mention do
  @moduledoc """
  One person named with `@login` in a comment, who could reach its track.

  What puts the thread in that person's Inbox until they next read it.
  `inserted_at` is when they were named, which for an edit that adds them is
  later than the comment itself.
  """
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "thread_comment_mentions" do
    belongs_to :comment, Ravix.Comments.Comment, primary_key: true
    belongs_to :user, Ravix.Accounts.User, primary_key: true
    field :inserted_at, :utc_datetime_usec
  end
end
