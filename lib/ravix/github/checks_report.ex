defmodule Ravix.GitHub.ChecksReport do
  @moduledoc """
  What GitHub thinks of a track's branch, as the Checks panel shows it.

  Not a GitHub shape -- `Ravix.GitHub.Shapes` holds those -- but Ravix's own
  answer assembled from three reads: the branch's head sha, the check runs
  against it, and the pull request it belongs to if there is one.

  `pushed` is the question the panel actually asks first, and it is not the
  same as having no checks: a branch GitHub has never seen reports `pushed:
  false` with `sha: nil`, where a pushed branch nothing runs on reports
  `pushed: true` with an empty `runs`. Telling somebody "no checks yet" when
  the truth is "you have not pushed" is how a person waits for a CI run that
  was never going to start.

  A struct with `@enforce_keys`, so the panel reading a field can be sure
  `read_checks/6` filled it in. It used to be a bare map that the template
  read with `@panel_data[:runs] || []` -- an `Access` read that answers `nil`
  for a key that does not exist, which makes a missing field indisting-
  uishable from an empty one and both of them unfalsifiable.
  """

  alias Ravix.GitHub.Shapes

  @enforce_keys [:ref, :sha, :pushed, :runs, :pull]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          ref: String.t(),
          sha: String.t() | nil,
          pushed: boolean(),
          runs: [Shapes.CheckRun.t()],
          pull: Shapes.PullRef.t() | nil
        }
end
