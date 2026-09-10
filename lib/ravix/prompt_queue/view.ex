defmodule Ravix.PromptQueue.View do
  @moduledoc """
  A waiting prompt as the composer shows it.

  The row plus one answer the row cannot give: `can_cancel`, which depends
  on who is looking. Anyone may withdraw their own prompt and the owner may
  withdraw anybody's, but nobody may withdraw one that is already on its way
  to the machine -- cancelling a send that has left is a promise this cannot
  keep.

  A struct with `@enforce_keys` rather than the bare map it was, so a field
  added here and forgotten in `present/3` raises where it is built.
  """

  alias Ravix.PromptQueue.Item

  @enforce_keys [
    :id,
    :prompt,
    :image_count,
    :author_login,
    :created_at,
    :status,
    :error,
    :can_cancel
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          prompt: String.t() | nil,
          image_count: non_neg_integer(),
          author_login: String.t(),
          created_at: DateTime.t(),
          status: Item.status(),
          error: String.t() | nil,
          can_cancel: boolean()
        }
end
