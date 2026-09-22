defmodule Ravix.Tracks.Origin do
  @moduledoc """
  How a track was started: a pull request, an issue, a branch, or nothing.

  This was four map literals and two `@type`s that disagreed with each other.
  `Ravix.Tracks.read_origin/2` built four keys, `origin_of/1` built the same
  four, `origin_info/1` built five, and `opening_prompt/4` took one of those
  and rebuilt it back down to four on the way to `Ravix.Spec`. The two
  declared shapes did not match either: `Ravix.Tracks.View.origin` required
  all five, while `Ravix.Spec.origin` required two, made `number` and `title`
  optional, and typed `kind` as *either* the atom or the string --- which is
  why `Spec` carried a `kind_of/1` that narrowed it a second time, and why
  `issue_lines/1` reached for the title through `origin[:title]` rather than
  naming it.

  `Ravix.Tracks` said of `read_origin/2` that "this is the boundary: past it
  the kind is one of `Track.origin_kinds/0` and nothing downstream re-checks
  it". That was not true while the thing crossing the boundary was a map,
  because a map makes no promise a later module can rely on. It is true now:
  the only way to hold an `Origin` is to have built one, `kind` is an atom
  from `Track.origin_kinds/0`, and `Spec` matches on it without re-narrowing.

  `url` is part of the struct rather than bolted on afterwards. It is derived
  --- GitHub's page for the pull request or issue, and `nil` for a branch, a
  blank track, or a project with no repository --- but it is derived *once*,
  where the origin is built, instead of at one of the three places that
  happened to need it.
  """

  alias Ravix.Tracks.Track

  @enforce_keys [:kind, :base, :number, :title, :url]
  defstruct @enforce_keys ++ [plan_id: nil, item_id: nil]

  @type t :: %__MODULE__{
          kind: Track.origin_kind(),
          base: String.t() | nil,
          number: integer() | nil,
          title: String.t() | nil,
          plan_id: String.t() | nil,
          item_id: String.t() | nil,
          url: String.t() | nil
        }

  @doc """
  The origin of a track that already exists, read back from its row.

  Every field is a column, so nothing is re-derived here: `url` is the one
  that was written when the track was opened, not a fresh guess at what
  GitHub would call it now.
  """
  @spec from_row(Track.t()) :: t()
  def from_row(%Track{} = row) do
    %__MODULE__{
      # No coercion: the column is one of four and the database enforces it.
      kind: row.origin_kind,
      base: row.origin_base,
      number: row.origin_number,
      title: row.origin_title,
      url: row.origin_url,
      plan_id: row.origin_plan_id,
      item_id: row.origin_item_id
    }
  end
end
