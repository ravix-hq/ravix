defmodule Ravix.Tracks.Header do
  @moduledoc """
  The ribbon at the top of a track: the four lines Conductor shows on a new
  thread.

  Only `copy_of` is rendered today. `branched_from`, `created` and
  `has_setup_script` are computed by `Ravix.Tracks.get/2` and read by
  nothing but a test --- and the last of them costs a Fountain round trip
  per track open, which `get/2` documents as worth paying for a "add a
  setup script" offer the ribbon does not yet make. They are kept because
  removing them is a decision about the ribbon rather than about types, and
  a struct is what makes the gap legible instead of leaving it in a map
  nobody can see the shape of.

  `created.files` is always nil, deliberately. The file count Conductor
  shows comes from copying a directory; nothing here copies anything, since
  a worktree shares the object store, so the honest answer is the directory
  alone rather than a number invented to match a screenshot.
  """

  @typedoc "The branch this track cut, and what it cut from."
  @type branched_from :: %{branch: String.t(), base: String.t()}

  @typedoc "Where the work happens. `files` is always nil; see the module documentation."
  @type created :: %{dir: String.t(), files: nil}

  @enforce_keys [:copy_of, :branched_from, :created, :has_setup_script]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          copy_of: String.t() | nil,
          branched_from: branched_from() | nil,
          created: created(),
          has_setup_script: boolean()
        }
end
